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

  def verify_hello_message(bootstrap, hello)
    hello.should_not be_nil
    hello["id"].should == bootstrap.uuid
    hello["ip"].should == bootstrap.local_ip
    hello["port"].should == bootstrap.file_viewer_port
    hello["version"].should == Dea::VERSION
  end
end

