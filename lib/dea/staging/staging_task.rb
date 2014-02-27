require 'tempfile'
require 'tmpdir'
require 'yaml'
require 'shellwords'

require 'container/container'

require 'dea/utils/download'
require 'dea/utils/upload'
require 'dea/promise'
require 'dea/task'
require 'dea/env'
require 'dea/staging/admin_buildpack_downloader'
require 'dea/staging/staging_task_workspace'
require 'dea/staging/staging_message'
require 'dea/loggregator'

module Dea
  class StagingTask < Task
    class StagingError < StandardError
      def initialize(msg)
        super("Error staging: #{msg}")
      end
    end

    class StagingTaskStoppedError < StagingError
      def initialize
        super('task stopped')
      end
    end

    include_platform_compat
    abstract_method :promise_prepare_staging_log_script,
                    :promise_app_dir_script,
                    :promise_unpack_app_script,
                    :promise_pack_app_script,
                    :build_download_destination_path,
                    :promise_log_upload_started_script,
                    :promise_pack_buildpack_cache_script,
                    :promise_unpack_buildpack_cache_script,
                    :staging_command
                    
    attr_reader :bootstrap, :dir_server, :staging_message, :task_id, :droplet_sha1

    def initialize(bootstrap, dir_server, staging_message, buildpacks_in_use, custom_logger=nil)
      super(bootstrap.config, custom_logger)
      @bootstrap = bootstrap
      @dir_server = dir_server
      @staging_message = staging_message
      @task_id = staging_message.task_id
      @buildpacks_in_use = buildpacks_in_use

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
          if error
            logger.info 'staging.task.failed',
              error: error, backtrace: error.backtrace
          else
            logger.info 'staging.task.completed'
          end

          unless error
            begin
              resolve_staging_upload
            rescue => e
              logger.info 'staging.task.upload-failed',
                error: e,
                backtrace: e.backtrace

              error = e
            end
          end

          trigger_after_complete(error)

          raise(error) if error
        ensure
          promise_destroy.resolve
          FileUtils.rm_rf(workspace.workspace_dir)
        end
      end
    end

    def workspace
      @workspace ||= StagingTaskWorkspace.new(
        config['base_dir'],
        staging_message,
        @buildpacks_in_use
      )
    end

    def task_log
      File.read(workspace.staging_log_path) if File.exists?(workspace.staging_log_path)
    end

    def streaming_log_url
      @dir_server.staging_task_file_url_for(task_id, workspace.warden_staging_log)
    end

    def task_info
      File.exists?(workspace.staging_info_path) ? YAML.load_file(workspace.staging_info_path) : {}
    end

    def detected_buildpack
      task_info['detected_buildpack']
    end

    def memory_limit_mb
      [(config.minimum_staging_memory_mb).to_i, staging_message.start_message.mem_limit.to_i].max
    end

    def memory_limit_in_bytes
      memory_limit_mb * 1024 * 1024
    end
    alias :used_memory_in_bytes :memory_limit_in_bytes

    def disk_limit_mb
      [(config.minimum_staging_disk_mb).to_i, staging_message.start_message.disk_limit.to_i].max
    end

    def disk_limit_in_bytes
      disk_limit_mb * 1024 * 1024
    end

    def disk_inode_limit
      config.staging_disk_inode_limit
    end

    def stop(&callback)
      stopping_promise = Promise.new do |p|
        logger.info 'staging.task.stopped'

        @after_complete_callback = nil # Unregister after complete callback
        promise_stop.resolve if container.handle
        p.deliver
      end

      Promise.resolve(stopping_promise) do |error, _|
        trigger_after_stop(StagingTaskStoppedError.new)
        callback.call(error) unless callback.nil?
      end
    end

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

    def promise_prepare_staging_log
      Promise.new do |p|
        script = promise_prepare_staging_log_script(workspace.warden_staged_dir, workspace.warden_staging_log)

        logger.info 'staging.task.preparing-log', script: script

        container.run_script(:app, script)

        p.deliver
      end
    end

    def promise_app_dir
      Promise.new do |p|
        # Some buildpacks seem to make assumption that /app is a non-empty directory
        # See: https://github.com/heroku/heroku-buildpack-python/blob/master/bin/compile#L46
        script = promise_app_dir_script

        logger.info 'staging.task.making-app-dir', script: script

        container.run_script(:app, script, true)

        p.deliver
      end
    end

    def promise_stage
      Promise.new do |p|
        script = staging_command
        logger.debug 'staging.task.execute-staging', script: script

        spawn_response = container.spawn(script)
        @warden_job_id = spawn_response.job_id
        bootstrap.snapshot.save
        begin
          Timeout.timeout(staging_timeout + staging_timeout_grace_period) do
            container.link_or_raise(@warden_job_id)
          end
          p.deliver
        rescue Container::WardenError => staging_error
          logger.error('staging.task.execute-staging.failed', error: staging_error)
          p.fail(staging_error)
        rescue Timeout::Error => timeout_error
          logger.error('staging.task.execute-staging.timed-out', error: timeout_error)
          p.fail(timeout_error)
        end
      end
    end

    def promise_task_log
      Promise.new do |p|
        logger.info 'staging.task-log.copying-out',
          source: workspace.warden_staging_log,
          destination: workspace.staging_log_path

        copy_out_request(workspace.warden_staging_log, File.dirname(workspace.staging_log_path))
        p.deliver
      end
    end

    def promise_staging_info
      Promise.new do |p|
        logger.info 'staging.task-info.copying-out',
          source: workspace.warden_staging_info,
          destination: workspace.staging_info_path

        copy_out_request(workspace.warden_staging_info, File.dirname(workspace.staging_info_path))
        p.deliver
      end
    end

    def promise_unpack_app
      Promise.new do |p|
        logger.info 'staging.task.unpacking-app', destination: workspace.warden_unstaged_dir

        script = promise_unpack_app_script(
          workspace.downloaded_app_package_path,
          workspace.warden_staging_log,
          workspace.warden_unstaged_dir
        )

        loggregator_emit_result container.run_script(:app, script)

        p.deliver
      end
    end

    def promise_pack_app
      Promise.new do |p|
        script = promise_pack_app_script(
          workspace.warden_staged_dir,
          workspace.warden_staged_droplet
        )
        logger.info 'staging.task.packing-droplet'
        container.run_script(:app, script)
        p.deliver
      end
    end

    def promise_app_download
      Promise.new do |p|
        logger.info 'staging.app-download.starting', uri: staging_message.download_uri

        download_destination = build_download_destination_path

        Download.new(staging_message.download_uri, download_destination, nil, logger).download! do |error|
          if error
            logger.debug 'staging.app-download.failed',
              duration: p.elapsed_time,
              error: error,
              backtrace: error.backtrace

            p.fail(error)
          else
            File.rename(download_destination.path, workspace.downloaded_app_package_path)
            File.chmod(0744, workspace.downloaded_app_package_path)

            logger.debug 'staging.app-download.completed',
              duration: p.elapsed_time,
              destination: workspace.downloaded_app_package_path

            p.deliver
          end
        end
      end
    end

    def promise_log_upload_started
      Promise.new do |p|
        script = promise_log_upload_started_script(
          workspace.warden_staged_droplet,
          workspace.warden_staging_log
        )
        loggregator_emit_result container.run_script(:app, script)
        p.deliver
      end
    end

    def promise_app_upload
      Promise.new do |p|
        logger.info 'staging.droplet-upload.starting',
          source: workspace.staged_droplet_path,
          destination: staging_message.upload_uri

        Upload.new(workspace.staged_droplet_path, staging_message.upload_uri, logger).upload! do |error|
          if error
            logger.info 'staging.task.droplet-upload-failed',
              duration: p.elapsed_time,
              destination: staging_message.upload_uri,
              error: error,
              backtrace: error.backtrace

            p.fail(error)
          else
            logger.info 'staging.task.droplet-upload-completed',
              duration: p.elapsed_time,
              destination: staging_message.upload_uri

            p.deliver
          end
        end
      end
    end

    def promise_buildpack_cache_upload
      Promise.new do |p|
        logger.info 'staging.buildpack-cache-upload.starting',
          source: workspace.staged_buildpack_cache_path,
          destination: staging_message.buildpack_cache_upload_uri

        Upload.new(workspace.staged_buildpack_cache_path, staging_message.buildpack_cache_upload_uri, logger).upload! do |error|
          if error
            logger.info 'staging.task.buildpack-cache-upload-failed',
              duration: p.elapsed_time,
              destination: staging_message.buildpack_cache_upload_uri,
              error: error,
              backtrace: error.backtrace

            p.fail(error)
          else
            logger.info 'staging.task.buildpack-cache-upload-completed',
              duration: p.elapsed_time,
              destination: staging_message.buildpack_cache_upload_uri

            p.deliver
          end
        end
      end
    end

    def promise_buildpack_cache_download
      Promise.new do |p|
        logger.info 'staging.buildpack-cache-download.starting',
          uri: staging_message.buildpack_cache_download_uri

        download_destination = Tempfile.new('buildpack-cache', workspace.tmpdir)

        Download.new(staging_message.buildpack_cache_download_uri, download_destination, nil, logger).download! do |error|
          if error
            logger.debug 'staging.buildpack-cache-download.failed',
              duration: p.elapsed_time,
              uri: staging_message.buildpack_cache_download_uri,
              error: error,
              backtrace: error.backtrace

          else
            File.rename(download_destination.path, workspace.downloaded_buildpack_cache_path)
            File.chmod(0744, workspace.downloaded_buildpack_cache_path)

            logger.debug 'staging.buildpack-cache-download.completed',
              duration: p.elapsed_time,
              destination: workspace.downloaded_buildpack_cache_path
          end

          p.deliver
        end
      end
    end

    def promise_copy_out
      Promise.new do |p|
        logger.info 'staging.droplet.copying-out',
          source: workspace.warden_staged_droplet,
          destination: workspace.staged_droplet_dir

        copy_out_request(workspace.warden_staged_droplet, workspace.staged_droplet_dir)

        p.deliver
      end
    end

    def promise_save_droplet
      Promise.new do |p|
        @droplet_sha1 = Digest::SHA1.file(workspace.staged_droplet_path).hexdigest
        bootstrap.droplet_registry[@droplet_sha1].local_copy(workspace.staged_droplet_path) do |error|
          if error
            logger.error 'staging.droplet.copy-failed',
              error: error, backtrace: error.backtrace

            p.fail
          else
            p.deliver
          end
        end
      end
    end

    def promise_save_buildpack_cache
      Promise.new do |p|
        resolve_and_log(promise_pack_buildpack_cache, 'staging.buildpack-cache.save') do |error, _|
          unless error
            begin
              promise_copy_out_buildpack_cache.resolve
              promise_buildpack_cache_upload.resolve
            rescue => e
              error = e
            end
          end

          if error
            p.fail(error)
          else
            p.deliver
          end
        end
      end
    end

    def promise_pack_buildpack_cache
      Promise.new do |p|
        # TODO: Ignore if buildpack cache is empty or does not exist
        script = promise_pack_buildpack_cache_script(
          workspace.warden_cache,
          workspace.warden_staged_buildpack_cache
        )
        container.run_script(:app, script)
        p.deliver
      end
    end

    def promise_unpack_buildpack_cache
      Promise.new do |p|
        if File.exists?(workspace.downloaded_buildpack_cache_path)
          logger.info 'staging.buildpack-cache.unpack',
            destination: workspace.warden_cache
          script = promise_unpack_buildpack_cache_script(workspace.downloaded_buildpack_cache_path,
                                                         workspace.warden_staging_log, 
                                                         workspace.warden_cache)
          loggregator_emit_result container.run_script(:app, script)
        end

        p.deliver
      end
    end

    def promise_copy_out_buildpack_cache
      Promise.new do |p|
        logger.info 'staging.buildpack-cache.copying-out',
          source: workspace.warden_staged_buildpack_cache,
          destination: workspace.staged_droplet_path

        copy_out_request(workspace.warden_staged_buildpack_cache, workspace.staged_droplet_dir)

        p.deliver
      end
    end

    def path_in_container(path)
      File.join(container.path, 'tmp', 'rootfs', path.to_s) if container.path
    end

    def staging_config
      config['staging']
    end

    def staging_timeout
      (staging_config['max_staging_duration'] || '900').to_f
    end

    def bind_mounts
      [workspace.workspace_dir, workspace.buildpack_dir, workspace.admin_buildpacks_dir].collect do |path|
        {'src_path' => path, 'dst_path' => path}
      end + config['bind_mounts']
    end

    def snapshot_attributes
      logger.info 'snapshot_attributes', properties: staging_message.properties
      {
        'staging_message' => staging_message.to_hash,
        'warden_container_path' => container.path,
        'warden_job_id' => @warden_job_id,
        'syslog_drain_urls' => syslog_drain_urls,
      }
    end

    private

    def syslog_drain_urls
      services = staging_message.properties['services'] || []
      services.map { |svc_hash| svc_hash['syslog_drain_url'] }.compact
    end

    def resolve_staging_setup
      workspace.prepare
      with_network = false
      container.create_container(
        bind_mounts: bind_mounts,
        limit_cpu: staging_config['cpu_limit_shares'],
        byte: disk_limit_in_bytes,
        inode: disk_inode_limit,
        limit_memory: memory_limit_in_bytes,
        setup_network: with_network
      )
      promises = [promise_app_download]
      promises << promise_buildpack_cache_download if staging_message.buildpack_cache_download_uri

      Promise.run_in_parallel(*promises)
      promise_update = Promise.new do |p|
        container.update_path_and_ip
        p.deliver
      end
      Promise.run_in_parallel(
        promise_prepare_staging_log,
        promise_app_dir,
        promise_update
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
        promise_unpack_buildpack_cache,
        promise_stage,
        promise_pack_app,
        promise_copy_out,
        promise_save_droplet,
        promise_log_upload_started,
        promise_staging_info
      )
    ensure
      promise_task_log.resolve
    end

    def resolve_staging_upload
      promise_app_upload.resolve
      promise_save_buildpack_cache.resolve
    end

    def run_plugin_path
      File.join(workspace.buildpack_dir, 'bin/run')
    end

    def staging_timeout_grace_period
      60
    end

    def loggregator_emit_result(result)
      if (result != nil)
        Dea::Loggregator.staging_emit(staging_message.app_id, result.stdout)
        Dea::Loggregator.staging_emit_error(staging_message.app_id, result.stderr)
      end
      result
    end
  end
  
  class WindowsStagingTask < StagingTask
    def promise_prepare_staging_log_script(warden_staged_dir, warden_staging_log)
      commands = [
        { :cmd => 'mkdir', :args => [ "#{warden_staged_dir}/logs" ] },
        { :cmd => 'touch', :args => [ warden_staging_log ] },
      ]
      commands.to_json
    end
    
    def promise_app_dir_script
      commands = [
        { :cmd => 'mkdir', :args => [ '@ROOT@/app' ] },
        { :cmd => 'touch', :args => [ '@ROOT@/app/support_heroku_buildpacks' ] },
      ]
      commands.to_json
    end
    
    def promise_unpack_app_script(downloaded_app_package_path, warden_staging_log, warden_unstaged_dir)
     commands = [
          { :cmd => 'ps1', :args => [
              %Q|$item_length = (Get-Item '#{downloaded_app_package_path}').Length|,
              %q|$item_length_str = '{0:N0}KB' -f ($item_length / 1KB)|,
              %Q|Add-Content -Encoding ASCII -Path #{warden_staging_log} "----> Downloaded app package ($item_length_str)"| ]
          },
          { :cmd => 'unzip', :args => [ downloaded_app_package_path, warden_unstaged_dir ] },
      ]
      commands.to_json
    end
    
    def promise_pack_app_script(warden_staged_dir, warden_staged_droplet)
      commands = [
        { :cmd => 'tar', :args => [ 'c', warden_staged_dir, warden_staged_droplet ] },
      ]
      commands.to_json
    end
    
    def build_download_destination_path
      Tempfile.new('app-package-download.tgz', workspace.workspace_dir)
    end
    
    def promise_log_upload_started_script(warden_staged_droplet, warden_staging_log)
      commands = [
        { :cmd => 'ps1', :args => [
            %Q|$item_length = (Get-Item '#{warden_staged_droplet}').Length|,
            %q|$item_length_str = '{0:N0}KB' -f ($item_length / 1KB)|,
            %Q|Add-Content -Encoding ASCII -Path #{warden_staging_log} "----> Uploading staged droplet ($item_length_str)"| ]
        },
      ]
      commands.to_json
    end
    
    def promise_pack_buildpack_cache_script(warden_cache, warden_staged_buildpack_cache)
      commands = [
          { :cmd => 'mkdir', :args => [ warden_cache ] },
          { :cmd => 'tar', :args => [ 'c', warden_cache, warden_staged_buildpack_cache ] },
      ]
      commands.to_json
    end
    
    def promise_unpack_buildpack_cache_script(downloaded_buildpack_cache_path, warden_staging_log, warden_cache)
      commands = [
          { :cmd => 'ps1', :args => [
              %Q|$item_length = (Get-Item '#{downloaded_buildpack_cache_path}').Length|,
              %q|$item_length_str = '{0:N0}KB' -f ($item_length / 1KB)|,
              %Q|Add-Content -Encoding ASCII -Path #{warden_staging_log} "----> Downloaded app buildpack cache ($item_length_str)"| ]
          },
          { :cmd => 'mkdir', :args => [ warden_cache ] },
          { :cmd => 'tar', :args => [ 'x', warden_cache, downloaded_buildpack_cache_path ] }
      ]
      commands.to_json
    end
    
    def staging_command

      staging_config_path = ''
      if staging_config['environment'].has_key?('PATH')
        staging_config_path = staging_config['environment']['PATH'].gsub(File::SEPARATOR, File::ALT_SEPARATOR || File::SEPARATOR)
      else
        staging_config_path = File.dirname(config['dea_ruby']).gsub(File::SEPARATOR, File::ALT_SEPARATOR || File::SEPARATOR)
      end

      staging_environment = PlatformCompat.to_env( {
        "BUILDPACK_CACHE" => staging_config["environment"]["BUILDPACK_CACHE"],
        "STAGING_TIMEOUT" => staging_timeout,
        "PATH" => "$env:PATH;#{staging_config_path}",
        "CONTAINER_ROOT" => "@ROOT@"
        })
      
      args = [ '# DEBUGGER' ]
      args << staging_environment
      args << %Q!#{config['dea_ruby']} '#{run_plugin_path}' '#{workspace.plugin_config_path}' 2>&1 | Out-File -Append -Encoding ASCII -FilePath '#{workspace.warden_staging_log}'!
      args.flatten!

      commands = [
        { :cmd => 'replace-tokens', :args => [ workspace.plugin_config_path ] }, 
        { :cmd => 'ps1', :args => args }
      ]

      commands.to_json
    end
  end
  
  class LinuxStagingTask < StagingTask
    def promise_prepare_staging_log_script(warden_staged_dir, warden_staging_log)
      script = "mkdir -p #{warden_staged_dir}/logs && touch #{warden_staging_log}"
    end
    
    def promise_app_dir_script
      'mkdir -p /app && touch /app/support_heroku_buildpacks && chown -R vcap:vcap /app'
    end
    
    def promise_unpack_app_script(downloaded_app_package_path, warden_staging_log, warden_unstaged_dir)
      return <<-BASH
        set -o pipefail
        package_size=`du -h #{downloaded_app_package_path} | cut -f1`
        echo "-----> Downloaded app package ($package_size)" | tee -a #{warden_staging_log}
        unzip -q #{downloaded_app_package_path} -d #{warden_unstaged_dir}
      BASH
    end
    
    def promise_pack_app_script(warden_staged_dir, warden_staged_droplet)
      return <<-BASH
          cd #{warden_staged_dir} &&
          COPYFILE_DISABLE=true tar -czf #{warden_staged_droplet} .
      BASH
    end
    
    def build_download_destination_path
      Tempfile.new('app-package-download.tgz')
    end
    
    def promise_log_upload_started_script(warden_staged_droplet, warden_staging_log)
      return <<-BASH
        set -o pipefail
        droplet_size=`du -h #{warden_staged_droplet} | cut -f1`
        echo "-----> Uploading droplet ($droplet_size)" | tee -a #{warden_staging_log}
      BASH
    end
    
    def promise_pack_buildpack_cache_script(warden_cache, warden_staged_buildpack_cache)
      return <<-BASH
          mkdir -p #{warden_cache} &&
          cd #{warden_cache} &&
          COPYFILE_DISABLE=true tar -czf #{warden_staged_buildpack_cache} .
      BASH
    end
    
    def promise_unpack_buildpack_cache_script(downloaded_buildpack_cache_path, warden_staging_log, warden_cache)
      return <<-BASH
          set -o pipefail
          package_size=`du -h #{downloaded_buildpack_cache_path} | cut -f1`
          echo "-----> Downloaded app buildpack cache ($package_size)" | tee -a #{warden_staging_log}
          mkdir -p #{warden_cache}
          tar xfz #{downloaded_buildpack_cache_path} -C #{warden_cache}
      BASH
    end
    
    def staging_command
      env = Env.new(staging_message, self)

      [
        'set -o pipefail;',
        env.exported_environment_variables,
        config['dea_ruby'],
        run_plugin_path,
        workspace.plugin_config_path,
        "| tee -a #{workspace.warden_staging_log}"
      ].join(' ')
    end
  end
end
