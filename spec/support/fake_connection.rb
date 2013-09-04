require "dea/promise"

class FakeConnection

  attr_reader :host_ip, :path

  def initialize
    @responses = {}
  end

  def set_fake_properties(options)
    @host_ip = options[:host_ip]
    @path = options[:path]
  end

  def set_fake_response(request_type, response)
    @responses[request_type] = response
  end

  def promise_call(request)
    Dea::Promise.new do |promise|
      promise.deliver(@responses[request.class])
    end
  end
end