require 'dea/staging/staging_task'
require 'dea/loggregator'

module Dea::Responders
  class HttpStaging

    def initialize(stager, cc_client)
      @stager = stager
      @cc_client = cc_client
    end

    def handle(request)
        message = StagingMessage.new(request)
        message.set_responder do |params, &blk|
          @cc_client.send_staging_response(params) { blk.call if blk }
        end
        
        task = @stager.create_task(message)
        return unless task

        task.start
      rescue => e
        logger.error('staging.handle.http.failed', error: e, backtrace: e.backtrace)
    end
  end
end
