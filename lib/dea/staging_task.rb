require "tempfile"
require "tmpdir"
require "yaml"

require "vcap/staging"
require "dea/utils/download"
require "dea/utils/upload"
require "dea/promise"
require "dea/task"

module Dea
  class StagingTask < Task
    DROPLET_FILE = "droplet.tgz"
    STAGING_LOG = "staging_task.log"

    WARDEN_UNSTAGED_DIR = "/tmp/unstaged"
    WARDEN_STAGED_DIR = "/tmp/staged"
    WARDEN_STAGED_DROPLET = "/tmp/#{DROPLET_FILE}"
    WARDEN_CACHE = "/tmp/cache"
    WARDEN_STAGING_LOG = "#{WARDEN_STAGED_DIR}/logs/#{STAGING_LOG}"

    attr_reader :bootstrap, :dir_server, :attributes
    attr_reader :container_path

    def initialize(bootstrap, dir_server, attributes, custom_logger=nil)
      super(bootstrap.config, custom_logger)

      @bootstrap = bootstrap
      @dir_server = dir_server
      @attributes = attributes.dup

      logger.user_data[:task_id] = task_id
    end

    def task_id
      @task_id ||= VCAP.secure_uuid
    end

    def task_log
      File.read(staging_log_path) if File.exists?(staging_log_path)
    end

    def streaming_log_url
      @dir_server.staging_task_file_url_for(task_id, WARDEN_STAGING_LOG)
    end

    def start
      staging_promise = Promise.new do |p|
        logger.info("Starting staging task")
        logger.info("Setting up temporary directories")
        logger.info("Working dir in #{workspace_dir}")

        resolve_staging_setup
        resolve_staging
        p.deliver
      end

      Promise.resolve(staging_promise) do |error, _|
        finish_task(error)
      end
    end

    def finish_task(error)
      logger.info("Finished staging task")
      trigger_after_complete(error)
      raise(error) if error
    ensure
      clean_workspace
    end
    private :finish_task

    def after_setup_callback(&blk)
      @after_setup_callback = blk
    end

    def trigger_after_setup(error)
      @after_setup_callback.call(error) if @after_setup_callback
    end
    private :trigger_after_setup

    def after_complete_callback(&blk)
      @after_complete_callback = blk
    end

    def trigger_after_complete(error)
      @after_complete_callback.call(error) if @after_complete_callback
    end
    private :trigger_after_complete

    def prepare_workspace
      StagingPlugin::Config.to_file({
        "source_dir"   => WARDEN_UNSTAGED_DIR,
        "dest_dir"     => WARDEN_STAGED_DIR,
        "environment"  => attributes["properties"]
      }, plugin_config_path)

      platform_config = staging_config["platform_config"]
      platform_config["cache"] = WARDEN_CACHE
      File.open(platform_config_path, "w") { |f| YAML.dump(platform_config, f) }
    end

    def promise_prepare_staging_log
      Promise.new do |p|
        script = "mkdir -p #{WARDEN_STAGED_DIR}/logs && touch #{WARDEN_STAGING_LOG}"
        logger.info("Preparing staging log: #{script}")
        promise_warden_run(:app, script).resolve
        p.deliver
      end
    end

    def promise_app_dir
      Promise.new do |p|
        # Some buildpacks seem to make assumption that /app is a non-empty directory
        # See: https://github.com/heroku/heroku-buildpack-python/blob/master/bin/compile#L46
        # TODO possibly remove this if pull request is accepted
        script = "mkdir /app && touch /app/support_heroku_buildpacks && chown -R vcap:vcap /app"
        promise_warden_run(:app, script, true).resolve
        p.deliver
      end
    end

    def promise_stage
      Promise.new do |p|
        script = [
          staging_environment,
          config["dea_ruby"],
          run_plugin_path,
          plugin_config_path,
          "> #{WARDEN_STAGING_LOG} 2>&1"
        ].join(" ")

        logger.info("Staging: #{script}")

        begin
          promise_warden_run(:app, script).resolve
        ensure
          promise_task_log.resolve
        end

        p.deliver
      end
    end

    def promise_task_log
      Promise.new do |p|
        copy_out_request(WARDEN_STAGING_LOG, File.dirname(staging_log_path))
        logger.info "Staging task log: #{task_log}"
        p.deliver
      end
    end

    def promise_unpack_app
      Promise.new do |p|
        logger.info("Unpacking app to #{WARDEN_UNSTAGED_DIR}")

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
        logger.info("Downloading application from #{attributes["download_uri"]}")

        Download.new(attributes["download_uri"], workspace_dir, nil, logger).download! do |error, path|
          if error
            p.fail(error)
          else
            File.rename(path, downloaded_droplet_path)
            File.chmod(0744, downloaded_droplet_path)

            logger.debug("Moved droplet to #{downloaded_droplet_path}")
            p.deliver
          end
        end
      end
    end

    def promise_app_upload
      Promise.new do |p|
        Upload.new(staged_droplet_path, attributes["upload_uri"], logger).upload! do |error|
          if error
            p.fail(error)
          else
            logger.info("Uploaded app to #{attributes["upload_uri"]}")
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

    def promise_container_info
      Promise.new do |p|
        raise ArgumentError, "container handle must not be nil" unless container_handle

        request = ::Warden::Protocol::InfoRequest.new(:handle => container_handle)
        response = promise_warden_call(:info, request).resolve

        raise RuntimeError, "container path is not available" \
          unless @container_path = response.container_path

        p.deliver(response)
      end
    end

    def path_in_container(path)
      File.join(container_path, "tmp", "rootfs", path.to_s) if container_path
    end

    private

    def resolve_staging_setup
      prepare_workspace

      run_in_parallel(
        promise_app_download,
        promise_create_container,
      )
      run_in_parallel(
        promise_prepare_staging_log,
        promise_app_dir,
        promise_container_info,
      )

    rescue => e
      trigger_after_setup(e)
      raise
    else
      trigger_after_setup(nil)
    end

    def resolve_staging
      run_serially(
        promise_unpack_app,
        promise_stage,
        promise_pack_app,
        promise_copy_out,
        promise_app_upload,
        promise_destroy,
      )
    end

    def run_in_parallel(*promises)
      promises.each(&:run).each(&:resolve)
    end

    def run_serially(*promises)
      promises.each(&:resolve)
    end

    def clean_workspace
      FileUtils.rm_rf(workspace_dir)
    end

    def paths_to_bind
      [workspace_dir, shared_gems_dir, File.dirname(staging_config["platform_config"]["insight_agent"])]
    end

    def workspace_dir
      return @workspace_dir if @workspace_dir
      staging_base_dir = File.join(config["base_dir"], "staging")
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

    def staging_log_path
      @staging_log_path ||= File.join(workspace_dir, STAGING_LOG)
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
        "C_INCLUDE_PATH" => "#{staging_config["environment"]["C_INCLUDE_PATH"]}:#{ENV["C_INCLUDE_PATH"]}",
        "LIBRARY_PATH" => staging_config["environment"]["LIBRARY_PATH"],
        "LD_LIBRARY_PATH" => staging_config["environment"]["LD_LIBRARY_PATH"],
        "PATH" => "#{staging_config["environment"]["PATH"]}:#{ENV["PATH"]}"
      }.map {|k, v| "#{k}=#{v}"}.join(" ")
    end

    def staging_config
      config["staging"]
    end
  end
end
