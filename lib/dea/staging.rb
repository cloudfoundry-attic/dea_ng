require "tempfile"
require "tmpdir"
require "yaml"

require "vcap/staging"
require "dea/download"
require "dea/promise"
require "dea/task"

module Dea
  class Staging < Task

    MAX_STAGING_DURATION = 120

    DROPLET_FILE = "droplet.tgz"
    WARDEN_UNSTAGED_DIR = "/tmp/unstaged"
    WARDEN_STAGED_DIR = "/tmp/staged"
    WARDEN_STAGED_DROPLET = "/tmp/#{DROPLET_FILE}"
    WARDEN_CACHE = "/tmp/cache"
    BUFFER_SIZE = (1024 * 1024).freeze

    class UploadError < StandardError
      attr_reader :data

      def initialize(msg, data = {})
        @data = data
        uri = data[:uri] || "(unknown)"
        super("<staging> Error uploading: %s (%s)" % [uri, msg])
      end
    end

    attr_reader :attributes

    def initialize(bootstrap, attributes)
      super(bootstrap)
      @attributes = attributes.dup
    end

    def logger
      # TODO: add staging info
      tags = {}

      @logger ||= self.class.logger.tag(tags)
    end

    def start(&callback)
      staging_promise = Promise.new do |p|
        logger.info("<staging> Starting staging task")
        logger.info("<staging> Setting up temporary directories")
        logger.info("<staging> Working dir in #{workspace_dir}")

        prepare_workspace

        [ promise_app_download, promise_create_container ].each(&:run).each(&:resolve)

        [
            promise_unpack_app,
            promise_stage,
            promise_pack_app,
            promise_copy_out,
            promise_app_upload,
            promise_destroy
        ].each(&:resolve)

        p.deliver
      end

      staging_promise.resolve

    ensure
      clean_workspace
    end

    def prepare_workspace
      plugin_config = {
        "source_dir"   => WARDEN_UNSTAGED_DIR,
        "dest_dir"     => WARDEN_STAGED_DIR,
        "environment"  => attributes["properties"]
      }

      StagingPlugin::Config.to_file(plugin_config, plugin_config_path)

      platform_config = config["platform_config"]
      platform_config["cache"] = WARDEN_CACHE

      File.open(platform_config_path, "w") { |f| YAML.dump(platform_config, f) }
    end

    def promise_stage
      Promise.new do |p|
        script = "mkdir #{WARDEN_STAGED_DIR} && "
        script += [staging_environment.map {|k, v| "#{k}=#{v}"}.join(" "),
                   bootstrap.config["dea_ruby"], run_plugin_path,
                   attributes["properties"]["framework_info"]["name"],
                   plugin_config_path].join(" ")
        logger.info("<staging> Running #{script}")
        promise_warden_run(:app, script).resolve

        p.deliver
      end
    end

    def promise_unpack_app
      Promise.new do |p|
        logger.info "<staging> Unpacking app to #{WARDEN_UNSTAGED_DIR}"
        script = "unzip -q #{downloaded_droplet_path} -d #{WARDEN_UNSTAGED_DIR}"
        promise_warden_run(:app, script).resolve

        p.deliver
      end
    end

    def promise_pack_app
      Promise.new do |p|
        script = "cd #{WARDEN_STAGED_DIR} && COPYFILE_DISABLE=true tar -czf #{WARDEN_STAGED_DROPLET} ."
        promise_warden_run(:app, script).resolve

        p.deliver
      end
    end

    def promise_app_download
      Promise.new do |p|
        logger.info("<staging> Downloading application from #{attributes["download_uri"]}")

        Download.new(attributes["download_uri"], workspace_dir).download! do |err, path|
          if !err
            File.rename(path, downloaded_droplet_path)
            File.chmod(0744, downloaded_droplet_path)

            logger.debug "<staging> Moved droplet to #{downloaded_droplet_path}"
            p.deliver
          else
            p.fail(err)
          end
        end
      end
    end

    def promise_app_upload
      Promise.new do |p|
        upload_app do |error|
          if error
            p.fail(error)
          else
            p.deliver
          end
        end
      end
    end

    def promise_copy_out
      Promise.new do |p|
        logger.info("Copying out to #{staged_droplet_path}")
        staged_droplet_dir = File.expand_path(File.dirname(staged_droplet_path))
        copy_out_request(WARDEN_STAGED_DROPLET, staged_droplet_dir)

        p.deliver
      end
    end

    def upload_app(&blk)
      @upload_waiting ||= []
      @upload_waiting << blk

      logger.debug "<staging> Waiting for upload to complete"

      if @upload_waiting.size == 1
        # Fire off request when this is the first call to #upload
        put_app do |err, path|
          if !err
            logger.debug "<staging> Uploaded droplet"
          end

          while blk = @upload_waiting.shift
            blk.call(err)
          end
        end
      end
    end

    def create_multipart_file(source)
      boundary = "mutipart-boundary-#{SecureRandom.uuid}"

      multipart_header = <<-DATA
--#{boundary}
Content-Disposition: form-data; name="upload[droplet]"; filename="droplet.tgz"
Content-Type: application/octet-stream

      DATA
      multipart_file = Tempfile.new("droplet", workspace_dir)

      File.open(source, "r") do |source_file|
        File.open(multipart_file.path, "a") do |dest_file|
          dest_file.write(multipart_header)

          while (record = source_file.read(BUFFER_SIZE))
            dest_file.write(record)
          end

          dest_file.write("\r\n--#{boundary}--")
        end
      end

      [boundary, multipart_file.path]
    end

    def put_app(&blk)
      logger.info("<staging> Starting upload")
      boundary, multipart_file_path = create_multipart_file(staged_droplet_path)

      http = EM::HttpRequest.new(attributes["upload_uri"]).post(
        head: {"Content-Type" => "multipart/form-data; boundary=#{boundary}"},
        file: multipart_file_path
      )

      logger.info("<staging> Sent upload request")

      context = { :upload_uri => attributes["upload_uri"] }

      http.errback do
        logger.info("<staging> Got upload error")
        error = UploadError.new("<staging> Response status: unknown", context)
        logger.warn(error.message, error.data)
        blk.call(error)
      end

      http.callback do
        logger.info("<staging> Got upload callback")
        http_status = http.response_header.status
        if http_status == 200
          logger.info("<staging> Uploaded app to #{attributes["upload_uri"]}")
          blk.call(nil, staged_droplet_path)
        else
          error = UploadError.new("<staging> HTTP status: #{http_status}", context)
          logger.warn(error.message, error.data)
          blk.call(error)
        end
      end
    end

    private

    def config
      bootstrap.config["staging"]
    end

    def runtime
      bootstrap.runtime(attributes["properties"]["runtime"], attributes["properties"]["runtime_info"])
    end

    def clean_workspace
      FileUtils.rm_rf(workspace_dir)
    end

    def paths_to_bind
      [workspace_dir, shared_gems_dir, File.dirname(config["platform_config"]["insight_agent"])]
    end

    def workspace_dir
      return @workspace_dir if @workspace_dir
      staging_base_dir = File.join(bootstrap.config["base_dir"], "staging")
      @workspace_dir = Dir.mktmpdir(nil, staging_base_dir)
      File.chmod(0755, @workspace_dir)
      @workspace_dir
    end

    def shared_gems_dir
      @shared_gems_dir ||= staging_plugin_spec.base_dir
    end

    def staged_droplet_path
      @staged_droplet_path ||= File.join(workspace_dir, "staged", DROPLET_FILE)
    end

    def plugin_config_path
      @plugin_config_path ||= File.join(workspace_dir, "plugin_config")
    end

    def platform_config_path
      @platform_config_path ||= File.join(workspace_dir, "platform_config")
    end

    def downloaded_droplet_path
      @downloaded_droplet_path ||= File.join(workspace_dir, "app.zip")
    end

    def run_plugin_path
      @run_plugin_path ||= File.join(staging_plugin_spec.gem_dir, "bin", "run_plugin")
    end

    def staging_plugin_spec
      @staging_plugin_spec ||= Gem::Specification.find_by_name("vcap_staging")
    end

    def cleanup(file)
      file.close
      yield
    ensure
      File.unlink(file.path) if File.exist?(file.path)
    end

    def staging_environment
      {
          "GEM_PATH" => shared_gems_dir,
          "PLATFORM_CONFIG" => platform_config_path,
          "C_INCLUDE_PATH" => "#{config["environment"]["C_INCLUDE_PATH"]}:#{ENV['C_INCLUDE_PATH']}",
          "LIBRARY_PATH" => config["environment"]["LIBRARY_PATH"],
          "LD_LIBRARY_PATH" => config["environment"]["LD_LIBRARY_PATH"],
          "PATH" => ENV['PATH']
      }
    end
  end
end
