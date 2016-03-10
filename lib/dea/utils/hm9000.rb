require 'dea/utils/uri_cleaner'

class HM9000
  INACTIVITY_TIMEOUT = 300.freeze

  attr_reader :logger

  def initialize(destination, custom_logger=nil)
    @destination = destination
    @logger = custom_logger || self.class.logger
  end

  def send_heartbeat(heartbeat)
    logger.info("send_heartbeat", destination: URICleaner.clean(@destination))

    http = EM::HttpRequest.new(@destination, inactivity_timeout: INACTIVITY_TIMEOUT).post( body: Yajl::Encoder.encode(heartbeat))

    http.errback do
      handle_error(http)
    end

    http.callback do
      handle_http_response(http)
    end
  end
  
  def handle_http_response(http)
    http_status = http.response_header.status

    if http_status == 202
      logger.debug("heartbeat accepted")
    else
      handle_error(http)
    end
  end


  def handle_error(http)
    open_connection_count = EM.connection_count # https://github.com/igrigorik/em-http-request/issues/190 says to check connection_count
    logger.warn("Sending heartbeat failed",
                destination: URICleaner.clean(@destination),
                connection_count: open_connection_count,
                http_error: http.error,
                http_status: http.response_header.status,
                http_response: http.response)
  end
end

