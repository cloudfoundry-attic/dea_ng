require "dea/staging_task"

module Dea::Responders
  class Stage
    def initialize(nats, bootstrap, config)
      @nats = nats
      @bootstrap = bootstrap
      @config = config
    end

    def start
      if @config["staging"] && @config["staging"]["enabled"]
        options = {:do_not_track_subscription => true, :queue => "staging"}
        @sid = @nats.subscribe("staging", options) do |message|
          handle(message)
        end
      end
    end

    def stop
      @nats.unsubscribe(@sid) if @sid
    end

    def handle(message)
      logger.info("<staging> Got staging request with #{message.data.inspect}")

      task = Dea::StagingTask.new(@bootstrap, nil, message.data)

      task.start do |error|
        result = {
          "task_id"  => task.task_id,
          "task_log" => task.task_log
        }
        result["error"] = error.to_s if error
        message.respond(result)
      end
    end
  end
end
