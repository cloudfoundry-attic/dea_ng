# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  it "should periodically send out messages on 'dea.advertise'" do
    advert = nil
    nats_mock.subscribe("dea.advertise") do |msg|
      advert = Yajl::Parser.parse(msg)
      EM.stop
    end

    em(:timeout => 1) do
      bootstrap.setup_sweepers
    end

    verify_advertisement(advert)
  end

  it "should publish on 'dea.advertise' if a message is published on 'dea.locate'" do
    advert = nil
    nats_mock.subscribe("dea.advertise") do |msg|
      advert = Yajl::Parser.parse(msg)
    end

    nats_mock.publish("dea.locate")

    verify_advertisement(advert)
  end

  def verify_advertisement(advert)
    advert.should_not be_nil
    advert["id"].should == @bootstrap.uuid
    advert["runtimes"].should == @bootstrap.runtimes.keys
  end
end
