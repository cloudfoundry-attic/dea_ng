require "tempfile"
require "tmpdir"
require "yaml"

require "dea/utils/download"
require "dea/utils/upload"
require "dea/promise"
require "dea/task"
require "dea/staging_task_workspace"

module Dea
  class StagingTask < Task
    DROPLET_FILE = "droplet.tgz"
    STAGING_LOG = "staging_task.log"

    WARDEN_UNSTAGED_DIR = "/tmp/unstaged"
    WARDEN_STAGED_DIR = "/tmp/staged"
    WARDEN_STAGED_DROPLET = "/tmp/#{DROPLET_FILE}"
    WARDEN_CACHE = "/tmp/cache"
    WARDEN_STAGING_LOG = "#{WARDEN_STAGED_DIR}/logs/#{STAGING_LOG}"

    class StagingError < StandardError
      def initialize(msg)
        super("Error staging: #{msg}")
      end
    end

    class StagingTaskStoppedError < StagingError
      def initialize
        super("task stopped")
      end
    end

    attr_reader :bootstrap, :dir_server, :attributes
    attr_reader :container_path
    # TODO: implement state behavior for staging tasks
    attr_reader :state

    def initialize(bootstrap, dir_server, attributes, custom_logger=nil)
      super(bootstrap.config, custom_logger)

      @bootstrap = bootstrap
      @dir_server = dir_server
      @attributes = attributes.dup

      logger.user_data[:task_id] = task_id
    end

    def start
      staging_promise = Promise.new do |p|
        resolve_staging_setup
        resolve_staging
        p.deliver
      end

      Promise.resolve(staging_promise) do |error, _|
        begin
          logger.info("Finished staging task")
          trigger_after_complete(error)
          raise(error) if error
        ensure
          FileUtils.rm_rf(workspace.workspace_dir)
        end
      end
    end

    def task_id
      @task_id ||= VCAP.secure_uuid
    end

    def workspace
      @workspace ||= StagingTaskWorkspace.new(config["base_dir"])
    end

    def task_log
      File.read(workspace.staging_log_path) if File.exists?(workspace.staging_log_path)
    end

    def streaming_log_url
      @dir_server.staging_task_file_url_for(task_id, workspace.warden_staging_log)
    end

    def memory_limit_in_bytes
      staging_config["memory_limit_mb"].to_i * 1024 * 1024
    end

    def disk_limit_in_bytes
      staging_config["disk_limit_mb"].to_i * 1024 * 1024
    end

    def stop(&callback)
      stopping_promise = Promise.new do |p|
        logger.info("Stopping staging task")

        @state = "STOPPED"
        promise_stop.resolve if container_handle
        p.deliver
      end

      Promise.resolve(stopping_promise) do |error, _|
        logger.info("Running resolve")
        trigger_after_stop(StagingTaskStoppedError.new)
        callback.call(error) unless callback.nil?
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

    def after_stop_callback(&blk)
      @after_stop_callback = blk
    end

    def trigger_after_stop(error)
      @after_stop_callback.call(error) if @after_stop_callback
    end
    private :trigger_after_stop

    def prepare_workspace
      plugin_config = {
        "source_dir"  => workspace.warden_unstaged_dir,
        "dest_dir"    => workspace.warden_staged_dir,
        "environment" => attributes["properties"]
      }

      platform_config = staging_config["platform_config"].merge("cache" => workspace.warden_cache)

      File.open(workspace.plugin_config_path, 'w') { |f| YAML.dump(plugin_config, f) }
      File.open(workspace.platform_config_path, "w") { |f| YAML.dump(platform_config, f) }
    end

    def promise_prepare_staging_log
      Promise.new do |p|
        script = "mkdir -p #{workspace.warden_staged_dir}/logs && touch #{workspace.warden_staging_log}"
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
          workspace.plugin_config_path,
          ">> #{workspace.warden_staging_log} 2>&1"
        ].join(" ")

        logger.info("Staging: #{script}")

        begin
          promise_warden_run(:app, script).resolve
        rescue Dea::Task::WardenError => error
          error = StagingTaskStoppedError.new if state == "STOPPED"
          p.fail(error)
        end

        p.deliver
      end
    end

    def promise_task_log
      Promise.new do |p|
        copy_out_request(workspace.warden_staging_log, File.dirname(workspace.staging_log_path))
        logger.info "Staging task log: #{task_log}"
        p.deliver
      end
    end

    def promise_unpack_app
      Promise.new do |p|
        logger.info("Unpacking app to #{workspace.warden_unstaged_dir}")

        promise_warden_run(:app, <<-BASH).resolve
          package_size=`du -h #{workspace.downloaded_droplet_path} | cut -f1`
          echo "-----> Downloaded app package ($package_size)" >> #{workspace.warden_staging_log}
          unzip -q #{workspace.downloaded_droplet_path} -d #{workspace.warden_unstaged_dir}
        BASH

        p.deliver
      end
    end

    def promise_pack_app
      Promise.new do |p|
        promise_warden_run(:app, <<-BASH).resolve
          cd #{workspace.warden_staged_dir} &&
          COPYFILE_DISABLE=true tar -czf #{workspace.warden_staged_droplet} .
        BASH
        p.deliver
      end
    end

    def promise_app_download
      Promise.new do |p|
        logger.info("Downloading application from #{attributes["download_uri"]}")

        Download.new(attributes["download_uri"], workspace.workspace_dir, nil, logger).download! do |error, path|
          if error
            p.fail(error)
          else
            File.rename(path, workspace.downloaded_droplet_path)
            File.chmod(0744, workspace.downloaded_droplet_path)

            logger.debug("Moved droplet to #{workspace.downloaded_droplet_path}")
            p.deliver
          end
        end
      end
    end

    def promise_log_upload_started
      Promise.new do |p|
        promise_warden_run(:app, <<-BASH).resolve
          droplet_size=`du -h #{workspace.warden_staged_droplet} | cut -f1`
          echo "-----> Uploading staged droplet ($droplet_size)" >> #{workspace.warden_staging_log}
        BASH
        p.deliver
      end
    end

    def promise_app_upload
      Promise.new do |p|
        Upload.new(workspace.staged_droplet_path, attributes["upload_uri"], logger).upload! do |error|
          if error
            p.fail(error)
          else
            logger.info("Uploaded app to #{attributes["upload_uri"]}")
            p.deliver
          end
        end
      end
    end

    def promise_log_upload_finished
      Promise.new do |p|
        promise_warden_run(:app, <<-BASH).resolve
          echo "-----> Uploaded droplet" >> #{workspace.warden_staging_log}
        BASH
        p.deliver
      end
    end

    def promise_copy_out
      Promise.new do |p|
        logger.info("Copying out to #{workspace.staged_droplet_path}")
        copy_out_request(workspace.warden_staged_droplet, workspace.staged_droplet_dir)

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

      Promise.run_in_parallel(
        promise_app_download,
        promise_create_container,
      )
      promise_limit_disk.resolve
      promise_limit_memory.resolve
      Promise.run_in_parallel(
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
      Promise.run_serially(
        promise_unpack_app,
        promise_stage,
        promise_pack_app,
        promise_copy_out,
        promise_log_upload_started,
        promise_app_upload,
        promise_log_upload_finished
      )
    ensure
      promise_task_log.resolve
      promise_destroy.resolve
    end

    def paths_to_bind
      [workspace.workspace_dir, buildpack_dir]
    end

    def run_plugin_path
      File.join(buildpack_dir, "bin/run")
    end

    def buildpack_dir
      File.expand_path("../../../buildpacks", __FILE__)
    end

    def staging_environment
      {
        "PLATFORM_CONFIG" => workspace.platform_config_path,
        "C_INCLUDE_PATH" => "#{staging_config["environment"]["C_INCLUDE_PATH"]}:#{ENV["C_INCLUDE_PATH"]}",
        "LIBRARY_PATH" => staging_config["environment"]["LIBRARY_PATH"],
        "LD_LIBRARY_PATH" => staging_config["environment"]["LD_LIBRARY_PATH"],
        "PATH" => "#{staging_config["environment"]["PATH"]}:#{ENV["PATH"]}",
        "BUILDPACK_CACHE" => staging_config["environment"]["BUILDPACK_CACHE"],
        "STAGING_TIMEOUT" => staging_timeout
      }.map { |k, v| "#{k}=#{v}" }.join(" ")
    end

    def staging_timeout
      (staging_config["max_staging_duration"] || "900").to_f
    end

    def staging_timeout_grace_period
      60
    end

    def staging_config
      config["staging"]
    end
  end
end
