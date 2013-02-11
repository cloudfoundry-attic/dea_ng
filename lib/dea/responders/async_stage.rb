require "dea/staging_task"

module Dea::Responders
  class AsyncStage
    def initialize(nats, bootstrap, dir_server, config)
      @nats = nats
      @bootstrap = bootstrap
      @dir_server = dir_server
      @config = config
    end

    def start
      if @config["staging"] && @config["staging"]["enabled"]
        options = {:do_not_track_subscription => true, :queue => "staging.async"}
        @sid = @nats.subscribe("staging.async", options) do |message|
          handle(message)
        end
      end
    end

    def stop
      @nats.unsubscribe(@sid) if @sid
    end

    def handle(message)
      logger.info("<staging> Got async staging request with #{message.data.inspect}")

      task = Dea::StagingTask.new(@bootstrap, @dir_server, message.data)

      task.after_setup do |error|
        message.respond(
          "task_id" => task.task_id,
          "streaming_log_url" => task.streaming_log_url,
          "error" => (error.to_s if error)
        )
      end

      task.start { |error| }
    end
  end
end
