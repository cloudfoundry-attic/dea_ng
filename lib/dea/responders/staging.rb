require 'dea/staging/staging_task'
require 'dea/loggregator'

module Dea::Responders
  class Staging
    attr_reader :bootstrap
    attr_reader :staging_task_registry
    attr_reader :dir_server
    attr_reader :resource_manager
    attr_reader :config

    def initialize(bootstrap, staging_task_registry, dir_server, resource_manager, config)
      @bootstrap = bootstrap
      @staging_task_registry = staging_task_registry
      @resource_manager = resource_manager
      @dir_server = dir_server
      @config = config
    end

    def create_task(staging_message) 
      app_id = staging_message.app_id
      logger = logger_for_app(app_id)

      Dea::Loggregator.emit(app_id, "Got staging request for app with id #{app_id}")
      logger.debug('staging.handle.start', request: staging_message.inspect)

      task = Dea::StagingTask.new(bootstrap, dir_server, staging_message, buildpacks_in_use, logger)
      unless resource_manager.could_reserve?(task.memory_limit_mb, task.disk_limit_mb)
        constrained_resource = resource_manager.get_constrained_resource(task.memory_limit_mb, task.disk_limit_mb)
        respond_to_request(staging_message,
                            task_id: task.task_id,
                            error: "Not enough #{constrained_resource} resources available")
        logger.error('staging.start.insufficient-resource',
                     app: app_id,
                     constrained_resource: constrained_resource)
        return
      end

      staging_task_registry.register(task)

      bootstrap.snapshot.save

      notify_completion(staging_message, task)
      notify_stop(staging_message, task)

      task
    end

    def stop_task(app_id)
      @staging_task_registry.each do |task|
        if app_id == task.staging_message.app_id
          task.stop
        end
      end
    rescue => e
      logger_for_app(app_id).error('staging.handle_stop.failed', error: e, backtrace: e.backtrace)
    end
    
    private

    def notify_completion(staging_message, task)
      task.after_complete_callback do |error|
        data = {
          task_id: task.task_id,
          detected_buildpack: task.detected_buildpack,
          buildpack_key: task.buildpack_key,
          droplet_sha1: task.droplet_sha1,
          detected_start_command: task.detected_start_command,
          procfile: task.procfile,
          app_id: staging_message.app_id
        }
        data[:error] = error.to_s if error
        data[:error_info] = task.error_info if task.error_info

        respond_to_request(staging_message, data) do

          # Unregistering the staging task will release the reservation of excess memory reserved for the app,
          # if the app requires more memory than the staging process.
          staging_task_registry.unregister(task)

          bootstrap.snapshot.save

          if !task.staging_message.start_message.message.empty? && !error && !@bootstrap.evac_handler.evacuating?
            start_message = task.staging_message.start_message.to_hash
            start_message['sha1'] = task.droplet_sha1
            # Now re-reserve the app's memory.  There may be a window between staging task unregistration and here
            # where the DEA could no longer have enough memory to start the app.  In that case, the health manager
            # should cause the app to be relocated on another DEA.
            bootstrap.start_app(start_message)
          end
        end
      end
    end
 
    # This can currently only be handled via nats. So we pass the stop request on the
    # actual response. We cannot extract this method to the handler because of the staging
    # task's stop method.
    def notify_stop(request, task)
      task.after_stop_callback do |error|
        respond_to_request(request, {
          task_id: task.task_id,
          error: (error.to_s if error),
        })

        staging_task_registry.unregister(task)

        bootstrap.snapshot.save
      end
    end

    def respond_to_request(request, params, &blk)
      blk.nil? ? request.respond(params) : request.respond(params) { blk.call }
    end

    def buildpacks_in_use
      staging_task_registry.flat_map { |task| task.staging_message.admin_buildpacks }.uniq
    end

    def logger_for_app(app_id)
      logger = Steno::Logger.new('Staging', Steno.config.sinks, level: Steno.config.default_log_level)
      logger.tag(app_guid: app_id)
    end
  end
end
