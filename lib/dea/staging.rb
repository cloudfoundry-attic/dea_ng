require "tempfile"
require "tmpdir"
require "yaml"

require "vcap/staging"
require "dea/download"
require "dea/upload"
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

    def start
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

      Promise.resolve(staging_promise) do |error, _|
        clean_workspace
        raise error if error
      end
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

        Download.new(attributes["download_uri"], workspace_dir).download! do |error, path|
          if !error
            File.rename(path, downloaded_droplet_path)
            File.chmod(0744, downloaded_droplet_path)

            logger.debug "<staging> Moved droplet to #{downloaded_droplet_path}"
            p.deliver
          else
            p.fail(error)
          end
        end
      end
    end

    def promise_app_upload
      Promise.new do |p|
        Upload.new(staged_droplet_path, attributes["upload_uri"]).upload! do |error|
          if !error
            logger.info("<staging> Uploaded app to #{attributes["upload_uri"]}")
            p.deliver
          else
            p.fail(error)
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
