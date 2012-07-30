# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  it "should publish a message on 'vcap.component.announce' on startup" do
    announcement = nil
    nats_mock.subscribe("vcap.component.announce") do |msg|
      announcement = Yajl::Parser.parse(msg)

      EM.stop
    end

    em(:timeout => 1) do
      bootstrap.start
    end

    announcement.should_not be_nil
  end

  it "should publish a message on 'dea.start' on startup" do
    hello = nil
    nats_mock.subscribe("dea.start") do |msg|
      hello = Yajl::Parser.parse(msg)
      EM.stop
    end

    em(:timeout => 1) do
      bootstrap.start
    end

    verify_hello_message(bootstrap, hello)
  end

  it "should respond to messages on 'dea.status' with enhanced hello messages" do
    status = nil
    nats_mock.subscribe("results") do |msg|
      status = Yajl::Parser.parse(msg)
      EM.stop
    end

    em(:timeout => 1) do
      bootstrap.start

      nats_mock.publish("dea.status", {}, "results")
    end

    verify_status_message(bootstrap, status)
  end

  def verify_hello_message(bootstrap, hello)
    hello.should_not be_nil
    hello["id"].should == bootstrap.uuid
    hello["ip"].should == bootstrap.local_ip
    hello["port"].should == bootstrap.file_viewer_port
    hello["version"].should == Dea::VERSION
  end

  def verify_status_message(bootstrap, status)
    verify_hello_message(bootstrap, status)

    %W[max_memory reserved_memory used_memory num_clients].each do |k|
      status.has_key?(k).should be_true
    end
  end
end

