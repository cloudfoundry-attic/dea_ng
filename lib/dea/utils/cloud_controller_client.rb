require 'dea/utils/uri_cleaner'

module Dea
  class CloudControllerClient
    INACTIVITY_TIMEOUT = 300.freeze

    attr_reader :logger

    def initialize(destination, custom_logger=nil)
      @destination = destination
      @logger = custom_logger || self.class.logger
    end

    def send_staging_response(response)
      destination = "#{@destination}/internal/dea/staging/#{response[:app_id]}/completed"
      logger.info('cloud_controller.staging_response.sending', destination: URICleaner.clean(destination))

      http = EM::HttpRequest.new(destination, inactivity_timeout: INACTIVITY_TIMEOUT).post( head: { 'content-type' => 'application/json' }, body: Yajl::Encoder.encode(response))

      http.errback do
        handle_error(http)
      end

      http.callback do
        handle_http_response(http)
      end
    end
    
    private 

    def handle_http_response(http)
      http_status = http.response_header.status

      if http_status == 200
        logger.info('cloud_controller.staging_response.accepted', http_status: http_status)
      else
        handle_error(http)
      end
    end


    def handle_error(http)
      open_connection_count = EM.connection_count # https://github.com/igrigorik/em-http-request/issues/190 says to check connection_count
      logger.warn('cloud_controller.staging_response.failed',
                  destination: URICleaner.clean(http.conn.uri),
                  connection_count: open_connection_count,
                  http_error: http.error,
                  http_status: http.response_header.status,
                  http_response: http.response)
    end
  end
end
