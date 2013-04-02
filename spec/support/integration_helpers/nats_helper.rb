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