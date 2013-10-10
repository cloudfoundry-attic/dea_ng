require "dea/staging/staging_task"

require "dea/loggregator"

module Dea::Responders
  class Staging
    attr_reader :nats
    attr_reader :dea_id
    attr_reader :bootstrap
    attr_reader :staging_task_registry
    attr_reader :dir_server
    attr_reader :config

    def initialize(nats, dea_id, bootstrap, staging_task_registry, dir_server, config)
      @nats = nats
      @dea_id = dea_id
      @bootstrap = bootstrap
      @staging_task_registry = staging_task_registry
      @dir_server = dir_server
      @config = config
    end

    def start
      return unless configured_to_stage?
      subscribe_to_staging
      subscribe_to_dea_specific_staging
      subscribe_to_staging_stop
    end

    def stop
      unsubscribe_from_staging
      unsubscribe_from_dea_specific_staging
      unsubscribe_from_staging_stop
    end

    def handle(message)
      app_id = message.data["app_id"]
      logger = logger_for_app(app_id)

      Dea::Loggregator.emit(app_id, "Got staging request for app with id #{app_id}")
      logger.info("staging.handle.start", request: message.data)

      task = Dea::StagingTask.new(bootstrap, dir_server, message.data, buildpacks_in_use, logger)
      staging_task_registry.register(task)

      bootstrap.save_snapshot

      notify_setup_completion(message, task)
      notify_completion(message, task)
      notify_upload(message, task)
      notify_stop(message, task)

      task.start
    rescue => e
      logger.error "staging.handle.failed", error: e, backtrace: e.backtrace
    end

    def handle_stop(message)
      staging_task_registry.each do |task|
        if message.data["app_id"] == task.attributes["app_id"]
          task.stop
        end
      end
    rescue => e
      logger.error "staging.handle_stop.failed", :error => e, :backtrace => e.backtrace
    end

    private

    def configured_to_stage?
      config["staging"] && config["staging"]["enabled"]
    end

    def subscribe_to_staging
      options = {:do_not_track_subscription => true, :queue => "staging"}
      @staging_sid = nats.subscribe("staging", options) { |message| handle(message) }
    end

    def unsubscribe_from_staging
      nats.unsubscribe(@staging_sid) if @staging_sid
    end

    def subscribe_to_dea_specific_staging
      options = {:do_not_track_subscription => true}
      @dea_specified_staging_sid = nats.subscribe("staging.#{@dea_id}.start", options) { |message| handle(message) }
    end

    def unsubscribe_from_dea_specific_staging
      nats.unsubscribe(@dea_specified_staging_sid) if @dea_specified_staging_sid
    end

    def subscribe_to_staging_stop
      options = {:do_not_track_subscription => true}
      @staging_stop_sid = nats.subscribe("staging.stop", options) { |message| handle_stop(message) }
    end

    def unsubscribe_from_staging_stop
      nats.unsubscribe(@staging_stop_sid) if @staging_stop_sid
    end

    def notify_setup_completion(message, task)
      task.after_setup_callback do |error|
        respond_to_message(message, {
          :task_id => task.task_id,
          :streaming_log_url => task.streaming_log_url,
          :error => (error.to_s if error)
        })
      end
    end

    def notify_completion(message, task)
      task.after_complete_callback do |error|
        if message.data["start_message"] && !error
          message.data["start_message"]["sha1"] = task.droplet_sha1
          bootstrap.start_app(message.data["start_message"])
        end
      end
    end

    def notify_upload(message, task)
      task.after_upload_callback do |error|
        respond_to_message(message, {
          :task_id => task.task_id,
          :error => (error.to_s if error),
          :detected_buildpack => task.detected_buildpack,
          :droplet_sha1 => task.droplet_sha1
        })

        staging_task_registry.unregister(task)

        bootstrap.save_snapshot
      end
    end

    def notify_stop(message, task)
      task.after_stop_callback do |error|
        respond_to_message(message, {
          :task_id => task.task_id,
          :error => (error.to_s if error),
        })

        staging_task_registry.unregister(task)

        bootstrap.save_snapshot
      end
    end

    def respond_to_message(message, params)
      message.respond(
        "task_id" => params[:task_id],
        "task_streaming_log_url" => params[:streaming_log_url],
        "detected_buildpack" => params[:detected_buildpack],
        "error" => params[:error],
        "droplet_sha1" => params[:droplet_sha1]
      )
    end

    def logger_for_app(app_id)
      logger = Steno::Logger.new("Staging", Steno.config.sinks, :level => Steno.config.default_log_level)
      logger.tag(:app_guid => app_id)
    end

    private

    def buildpacks_in_use
      staging_task_registry.flat_map do |task|
        task.admin_buildpacks
      end.uniq
    end
  end
end
