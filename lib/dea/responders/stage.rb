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
      return unless configured_to_stage?

      options = {:do_not_track_subscription => true, :queue => "staging"}
      @sid = nats.subscribe("staging", options) { |message| handle(message) }
    end

    def stop
      nats.unsubscribe(@sid) if @sid
    end

    def handle(message)
      logger.info("<staging> Got #{"a" if message.data["async"]}sync staging request with #{message.data.inspect}")

      task = Dea::StagingTask.new(bootstrap, dir_server, message.data)
      staging_task_registry.register(task)

      notify_setup_completion(message, task) if message.data["async"]

      task.start do |error|
        respond_to_message(message, {
          :task_id => task.task_id,
          :task_log => task.task_log,
          :error => (error.to_s if error)
        })
        staging_task_registry.unregister(task)
      end
    end

    private

    def configured_to_stage?
      config["staging"] && config["staging"]["enabled"]
    end

    def notify_setup_completion(message, task)
      task.after_setup do |error|
        respond_to_message(message, {
          :task_id => task.task_id,
          :streaming_log_url => task.streaming_log_url,
          :error => (error.to_s if error)
        })
      end
    end

    def respond_to_message(message, params)
      message.respond(
        "task_id" => params[:task_id],
        "task_log" => params[:task_log],
        "task_streaming_log_url" => params[:streaming_log_url],
        "error" => params[:error],
      )
    end
  end
end
