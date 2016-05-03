require 'dea/utils/uri_cleaner'
require 'httpclient'

class HM9000
  attr_reader :logger

  def initialize(destination, key_file, cert_file, ca_file, timeout, custom_logger=nil)
    @destination = URI.join(destination, '/dea/heartbeat')
    @logger = custom_logger || self.class.logger

    client = HTTPClient.new
    client.connect_timeout = 5
    client.receive_timeout = 5
    client.send_timeout = 5
    client.keep_alive_timeout = timeout

    ssl = client.ssl_config
    ssl.verify_mode = OpenSSL::SSL::VERIFY_PEER

    ssl.set_client_cert_file(cert_file, key_file)

    ssl.clear_cert_store
    ssl.add_trust_ca(ca_file)

    @http_client = client
  end

  def send_heartbeat(heartbeat, &callback)
    logger.debug('hm9000.heartbeat.sending', destination: URICleaner.clean(@destination))

    connection = @http_client.post_async(@destination, header: { 'Content-Type' => 'application/json' }, body: Yajl::Encoder.encode(heartbeat))
    EM.defer(
      lambda do
        begin
          response = connection.pop
          handle_http_response(response, callback)
        rescue => e
          logger.error('hm9000.heartbeat.failed', error: e)
        end
      end
    )
  end

private

  def handle_http_response(response, callback)
    http_status = response.status
    if http_status == 202
      logger.debug('hm9000.heartbeat.accepted')
      callback.call(response) if callback
    else
      handle_error(response, callback)
    end
  end


  def handle_error(response, callback)
    logger.warn(
      'hm9000.heartbeat.failed',
      destination: URICleaner.clean(@destination),
      http_status: response.status,
      http_response: response.content
    )

    callback.call(response) if callback
  end
end
