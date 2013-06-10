require "dea/staging_task"

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
      should_do_async_staging = message.data["async"]

      logger = logger_for_app(message.data["app_id"])
      logger.info("Got #{"a" if should_do_async_staging}sync staging request with #{message.data.inspect}")

      task = Dea::StagingTask.new(bootstrap, dir_server, message.data, logger)
      staging_task_registry.register(task)

      notify_setup_completion(message, task) if should_do_async_staging
      notify_completion(message, task)
      notify_stop(message, task)

      task.start
    end

    def handle_stop(message)
      staging_task_registry.each do |task|
        if message.data["app_id"] == task.attributes["app_id"]
          task.stop
        end
      end
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
        respond_to_message(message, {
          :task_id => task.task_id,
          :task_log => task.task_log,
          :error => (error.to_s if error),
          :detected_buildpack => task.detected_buildpack
        })
        staging_task_registry.unregister(task)
      end
    end

    def notify_stop(message, task)
      task.after_stop_callback do |error|
        respond_to_message(message, {
          :task_id => task.task_id,
          :error => (error.to_s if error),
        })
        staging_task_registry.unregister(task)
      end
    end

    def respond_to_message(message, params)
      message.respond(
        "task_id" => params[:task_id],
        "task_log" => params[:task_log],
        "task_streaming_log_url" => params[:streaming_log_url],
        "detected_buildpack" => params[:detected_buildpack],
        "error" => params[:error],
      )
    end

    def logger_for_app(app_id)
      logger = Steno::Logger.new("Staging", Steno.config.sinks, :level => Steno.config.default_log_level)
      logger.tag(:app_guid => app_id)
    end
  end
end
