require "yajl"
require "timeout"

class NatsHelper
  def connected?
    NATS.connected?
  end

  def request(key, data, options={})
    send_message(:request, key, data, options)
  end

  def publish(key, data, options={})
    send_message(:publish, key, data, options)
  end

  def with_subscription(key)
    response = nil

    NATS.start do
      yield if block_given?
      NATS.subscribe(key) do |resp|
        response = resp
        NATS.stop
      end
    end

    Yajl::Parser.parse(response) if response
  end

  def with_async_staging(message, first_response_blk, second_response_blk)
    response_number = 0
    NATS.start do
      sid = NATS.request("staging", message, :max => 2) do |response|
        response_number += 1
        response = Yajl::Parser.parse(response)
        if response_number == 1
          first_response_blk.call(response)
        elsif response_number == 2
          NATS.stop
          second_response_blk.call(response)
        end
      end

      NATS.timeout(sid, 10, :expected => 2) do
        NATS.stop
        fail "Timeout getting staging response"
      end
    end
  end

  private

  def send_message(method, key, data, options)
    response = nil

    if options[:async]
      _send_message(method, key, data) do |resp|
        response = resp
      end
    else
      NATS.start do
        sid = _send_message(method, key, data) do |resp|
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

  def _send_message(method, key, data, &block)
    NATS.public_send(method, key, Yajl::Encoder.encode(data), &block)
  end
end