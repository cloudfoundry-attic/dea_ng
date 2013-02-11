require "dea/staging_task"

module Dea::Responders
  class Stage
    attr_reader :nats
    attr_reader :bootstrap
    attr_reader :staging_task_registry
    attr_reader :dir_server
    attr_reader :config

    def initialize(nats, bootstrap, staging_task_registry, dir_server, config)
      @nats = nats
      @bootstrap = bootstrap
      @staging_task_registry = staging_task_registry
      @dir_server = dir_server
      @config = config
    end

    def start
      if config["staging"] && config["staging"]["enabled"]
        options = {:do_not_track_subscription => true, :queue => "staging"}
        @sid = nats.subscribe("staging", options) do |message|
          handle(message)
        end
      end
    end

    def stop
      nats.unsubscribe(@sid) if @sid
    end

    def handle(message)
      if message.data["async"]
        stage_async(message)
      else
        stage_sync(message)
      end
    end

    def stage_sync(message)
      logger.info("<staging> Got staging request with #{message.data.inspect}")

      task = Dea::StagingTask.new(bootstrap, dir_server, message.data)
      staging_task_registry.register(task)

      task.start do |error|
        result = {
          "task_id"  => task.task_id,
          "task_log" => task.task_log
        }
        result["error"] = error.to_s if error
        message.respond(result)

        staging_task_registry.unregister(task)
      end
    end

    def stage_async(message)
      logger.info("<staging> Got async staging request with #{message.data.inspect}")

      task = Dea::StagingTask.new(bootstrap, dir_server, message.data)
      staging_task_registry.register(task)

      task.after_setup do |error|
        message.respond(
          "task_id" => task.task_id,
          "streaming_log_url" => task.streaming_log_url,
          "error" => (error.to_s if error)
        )
      end

      task.start do |error|
        staging_task_registry.unregister(task)
      end
    end
  end
end
