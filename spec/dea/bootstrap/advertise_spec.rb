# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  before do
    @advertisement = nil
    nats_mock.subscribe("dea.advertise") do |msg|
      @advertisement = Yajl::Parser.parse(msg)
      done
    end
  end

  after do
    @advertisement.should_not be_nil

    @advertisement["id"].should == \
      bootstrap.uuid

    @advertisement["runtimes"].should == \
      bootstrap.runtimes.keys

    @advertisement["available_memory"].should == \
      bootstrap.resource_manager.resources["memory"].remain
  end

  it "should periodically send out messages on 'dea.advertise'" do
    bootstrap.unstub(:setup_sweepers)

    em(:timeout => 1) do
      bootstrap.setup
      bootstrap.start
    end
  end

  it "should publish on 'dea.advertise' if a message is published on 'dea.locate'" do
    em(:timeout => 1) do
      bootstrap.setup
      bootstrap.start

      nats_mock.publish("dea.locate")
    end
  end
end
