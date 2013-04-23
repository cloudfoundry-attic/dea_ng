# coding: UTF-8

require "nats/client"
require File.expand_path("mock_class", File.dirname(__FILE__))

# Defined specifically for NatsClientMock
class NatsInstance
  # NATS is actually a module which gets made into a class
  # and then instantiated by one of the EM.connect* methods
  include NATS
end

MockClass.define(:NatsClientMock, NatsInstance) do
  overrides :initialize do |options|
    @options = options
    @subscriptions = Hash.new { |h, k| h[k] = [] }
  end

  overrides :subscribe do |subject, opts={}, &callback|
    @subscriptions[subject] << callback
    callback # Consider block a subscription id
  end

  overrides :unsubscribe do |sid, opt_max=nil|
    @subscriptions.each do |_, blks|
      blks.delete(sid)
    end
  end

  overrides :publish do |subject, msg=nil, opt_reply=nil, &blk|
    receive_message(subject, msg, opt_reply)
  end

  overrides :request do |subject, data=nil, opts={}, &cb|
    inbox = nil

    if cb
      inbox = "nats_mock_request_#{Time.now.nsec}"
      subscribe(inbox, &cb)
    end

    publish(subject, data, inbox)
  end

  add :receive_message do |subject, data = {}, respond_to = nil|
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

module NatsClientMockHelpers
  def stub_nats
    before do
      @nats_mock = NatsClientMock.new({})
      NATS.should_receive(:connect).any_number_of_times do |opts|
        # By setting the max reconnect attempts to a large number, it gives us more time to recover from NATS outages
        opts[:max_reconnect_attempts].should == 999999
        nats_mock
      end
    end

    attr_reader :nats_mock
  end
end

RSpec.configure do |rspec_config|
  rspec_config.extend NatsClientMockHelpers
end