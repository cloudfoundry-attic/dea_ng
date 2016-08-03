require 'dea/staging/staging_task'
require 'dea/loggregator'

module Dea::Responders
  class NatsStaging
    def initialize(nats, dea_id, stager, config)
      @nats = nats
      @dea_id = dea_id
      @stager = stager
      @config = config
    end

    def start
      return unless configured_to_stage?
      subscribe_to_dea_specific_staging
      subscribe_to_staging_stop
    end

    def stop
      unsubscribe_from_dea_specific_staging
      unsubscribe_from_staging_stop
    end

    def handle(request)
      message = StagingMessage.new(request.data)
      message.set_responder do |params, &blk|
        request.respond(params) { blk.call if blk }
      end

      task = @stager.create_task(message)
      return unless task

      notify_setup_completion(request, task)

      task.start
    rescue => e
      logger.error('staging.handle.failed', error: e, backtrace: e.backtrace)
    end

    def handle_stop(message)
      @stager.stop_task(message.data['app_id'])
    end

    private

    def configured_to_stage?
      @config['staging'] && @config['staging']['enabled']
    end

    def subscribe_to_dea_specific_staging
      @dea_specified_staging_sid =
        @nats.subscribe("staging.#{@dea_id}.start", {do_not_track_subscription: true}) { |request| handle(request) }
    end

    def unsubscribe_from_dea_specific_staging
      @nats.unsubscribe(@dea_specified_staging_sid) if @dea_specified_staging_sid
    end

    def subscribe_to_staging_stop
      @staging_stop_sid =
        @nats.subscribe('staging.stop', {do_not_track_subscription: true}) { |request| handle_stop(request) }
    end

    def unsubscribe_from_staging_stop
      @nats.unsubscribe(@staging_stop_sid) if @staging_stop_sid
    end

    def notify_setup_completion(request, task)
      task.after_setup_callback do |error|
        request.respond({
          task_id: task.task_id,
          task_streaming_log_url: task.streaming_log_url,
          error: (error.to_s if error)
        })
      end
    end
  end
end
