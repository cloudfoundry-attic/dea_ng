# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  it "should periodically send out heartbeats on 'dea.heartbeat' for all instances" do
    bootstrap.unstub(:setup_sweepers)

    instances = []
    heartbeats = []

    # Unregister an instance with each heartbeat received
    nats_mock.subscribe("dea.heartbeat") do |msg, _|
      heartbeats << Yajl::Parser.parse(msg)
      if heartbeats.size == 5
        done
      else
        bootstrap.instance_registry.unregister(instances[heartbeats.size - 1])
      end
    end

    em(:timeout => 1) do
      bootstrap.setup
      bootstrap.start

      # Register instances
      5.times do |ii|
        instances << create_and_register_instance(bootstrap,
                                                  "application_id"      => ii,
                                                  "application_version" => ii,
                                                  "instance_index"      => ii)
      end
    end

    heartbeats.size.should == instances.size
    instances.size.times do |ii|
      heartbeats[ii].has_key?("dea").should be_true
      heartbeats[ii]["droplets"].size.should == (instances.size - ii)

      # Check that we received the correct heartbeats
      heartbeats[ii]["droplets"].each_with_index do |hb, jj|
        verify_instance_heartbeat(hb, instances[ii + jj])
      end
    end
  end

  it "should send a heartbeat upon receipt of a message on 'healthmanager.start'" do
    heartbeat = nil
    nats_mock.subscribe("dea.heartbeat") do |msg, _|
      heartbeat = Yajl::Parser.parse(msg)
      done
    end

    em(:timeout => 1) do
      bootstrap.setup
      bootstrap.start

      # Register instances
      2.times do |ii|
        create_and_register_instance(bootstrap, "application_id" => ii)
      end

      nats_mock.publish("healthmanager.start")
    end

    # Being a bit lazy here by not validating message returned, however,
    # that codepath is exercised by the periodic heartbeat tests.
    heartbeat.should_not be_nil
    heartbeat["droplets"].size.should == 2
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
