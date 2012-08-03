# coding: UTF-8

class NatsClientMock
  attr_reader :options

  def initialize(options)
    @options = options
    @subscriptions = Hash.new { |h, k| h[k] = [] }
  end

  def subscribe(subject, &blk)
    @subscriptions[subject] << blk
  end

  # Block omitted until needed
  def publish(*args)
    receive_message(*args)
  end

  def request(subject, data = {}, &blk)
    inbox = nil
    if block_given?
      inbox = "nats_mock_request_#{Time.now.nsec}"
      subscribe(inbox, &blk)
    end

    publish(subject, data, inbox)
  end

  def receive_message(subject, data = {}, respond_to = nil)
    if data.kind_of?(String)
      raw_data = data
    else
      raw_data = Yajl::Encoder.encode(data)
    end

    @subscriptions[subject].each do |blk|
      blk.call(raw_data, respond_to)
    end
  end
end
