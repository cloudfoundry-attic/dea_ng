# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  it "should periodically send out heartbeats on 'dea.heartbeat' for all instances" do
    # Register initial instances
    instances = 5.times.map do |ii|
      create_and_register_instance(bootstrap,
                                   "application_id"      => ii,
                                   "application_version" => ii,
                                   "instance_index"      => ii)
    end

    # Unregister an instance with each heartbeat received
    hbs = []
    nats_mock.subscribe("dea.heartbeat") do |msg, _|
      hbs << Yajl::Parser.parse(msg)
      if hbs.size == 5
        EM.stop
      else
        bootstrap.instance_registry.unregister(instances[hbs.size - 1])
      end
    end

    em(:timeout => 1) do
      bootstrap.setup_sweepers
    end

    hbs.size.should == instances.size
    instances.size.times do |ii|
      hbs[ii].has_key?("dea").should be_true
      hbs[ii]["droplets"].size.should == (instances.size - ii)

      # Check that we received the correct heartbeats
      hbs[ii]["droplets"].each_with_index do |hb, jj|
        verify_instance_heartbeat(hb, instances[ii + jj])
      end
    end
  end

  it "should send a heartbeat upon receipt of a message on 'healthmanager.start'" do
    # Register initial instances
    2.times do |ii|
      create_and_register_instance(bootstrap, "application_id" => ii)
    end

    hb = nil
    nats_mock.subscribe("dea.heartbeat") do |msg, _|
      hb = Yajl::Parser.parse(msg)
    end

    nats_mock.publish("healthmanager.start")

    # Being a bit lazy here by not validating message returned, however,
    # that codepath is exercised by the periodic heartbeat tests.
    hb.should_not be_nil
    hb["droplets"].size.should == 2
  end

  def verify_instance_heartbeat(hb, instance)
    hb_keys = %w[droplet version instance index state state_timestamp]
    hb.keys.should == hb_keys
    hb["droplet"].should == instance.application_id
    hb["version"].should == instance.application_version
    hb["instance"].should == instance.instance_id
    hb["index"].should == instance.instance_index
    hb["state"].should == instance.state
  end
end
