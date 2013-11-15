require "yajl"
require "timeout"

class NatsHelper
  def initialize(dea_config)
    @dea_config = dea_config
  end

  def connected?
    NATS.connected?
  end

  def request(key, data, options={})
    send_message(:request, key, data, options)
  end

  def publish(key, data, options={})
    send_message(:publish, key, data, options)
  end

  def with_nats(&blk)
    NATS.start(:uri => nats_servers, &blk)
  end

  def with_subscription(key)
    response = nil

    with_nats do
      yield if block_given?

      NATS.subscribe(key) do |resp|
        response = resp
        NATS.stop
      end
    end

    Yajl::Parser.parse(response) if response
  end

  def make_blocking_request(key, message, number_of_expected_responses, timeout=10)
    responses = []

    with_nats do
      sid = NATS.request(key, Yajl::Encoder.encode(message), :max => number_of_expected_responses) do |response|
        response = Yajl::Parser.parse(response)
        responses << response
        yield(responses.count - 1, response) if block_given?
        NATS.stop if responses.count == number_of_expected_responses
      end

      NATS.timeout(sid, timeout) do
        NATS.stop
        fail "Timeout getting response"
      end
    end

    responses
  end

  private

  def send_message(method, key, data, options)
    response = nil

    if options[:async]
      NATS.public_send(method, key, Yajl::Encoder.encode(data)) do |resp|
        response = resp
      end
    else
      with_nats do
        sid = NATS.public_send(method, key, Yajl::Encoder.encode(data)) do |resp|
          response = resp
          NATS.stop
        end

        if timeout = options[:timeout]
          NATS.timeout(sid, timeout) { NATS.stop }
        end
      end
    end

    Yajl::Parser.parse(response) if response
  end

  def nats_servers
    @dea_config["nats_servers"]
  end
end
