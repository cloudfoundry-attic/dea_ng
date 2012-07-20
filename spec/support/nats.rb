class NatsClientMock
  attr_reader :options

  def initialize(options)
    @options = options
    @subscriptions = Hash.new { |h, k| h[k] = [] }
  end

  def subscribe(subject, &blk)
    @subscriptions[subject] << blk
  end

  def receive_message(subject, data = {}, respond_to = nil)
    raw_data = Yajl::Encoder.encode(data)

    @subscriptions[subject].each do |blk|
      blk.call(raw_data, respond_to)
    end
  end
end
