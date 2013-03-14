require "yajl"

class NatsHelper
  def request(key, data)
    write(:request, key, data)
  end

  def publish(key, data)
    write(:publish, key, data)
  end

  private

  def write(method, key, data)
    response = nil
    NATS.start do
      NATS.public_send(method, key, Yajl::Encoder.encode(data)) do |resp|
        response = resp
        NATS.stop
      end
    end
    Yajl::Parser.parse(response) if response
  end
end