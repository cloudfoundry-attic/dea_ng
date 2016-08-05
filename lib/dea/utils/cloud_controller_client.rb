require 'dea/utils/uri_cleaner'

module Dea
  class CloudControllerClient
    INACTIVITY_TIMEOUT = 30.freeze
    MAX_RETRIES = 3.freeze

    attr_reader :logger

    def initialize(uuid, destination, custom_logger=nil)
      @uuid = uuid
      @destination = destination
      @logger = custom_logger || self.class.logger
    end

    def send_staging_response(response, &blk)
      response = response.merge( {:dea_id => @uuid} )
      # blk ? send(response, 1) { blk.call } : send(response, 1)
      send(response, 1) { blk.call if blk }
    end

    private

    def send(response, iteration, &blk)
      if iteration > MAX_RETRIES
        blk.call if blk
      else
        destination = URI.join(@destination, "/internal/dea/staging/#{response[:app_id]}/completed")
        logger.info('cloud_controller.staging_response.sending', destination: URICleaner.clean(destination), iteration: iteration)

        http = EM::HttpRequest.new(destination, inactivity_timeout: INACTIVITY_TIMEOUT).post( head: { 'content-type' => 'application/json' }, body: Yajl::Encoder.encode(response))

        http.errback do
          if handle_error(http)
            # blk ? send(response, iteration + 1) { blk.call } : send(response, iteration + 1)
            send(response, iteration + 1) { blk.call if blk }
          end
        end

        http.callback do
          if handle_http_response(http)
            # blk ? send(response, iteration + 1) { blk.call } : send(response, iteration + 1)
            send(response, iteration + 1) { blk.call if blk }
          else
            blk.call if blk
          end
        end
      end
    end

    def handle_http_response(http)
      http_status = http.response_header.status

      if http_status == 200
        logger.info('cloud_controller.staging_response.accepted', http_status: http_status)
        return false
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

      if http.response_header.status == 404 || http.response_header.status >= 500
        return true
      end

      return false
    end
  end
end
