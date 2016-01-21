# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  it "should periodically send out heartbeats on 'dea.heartbeat' for all instances" do
    allow(bootstrap).to receive(:setup_sweepers).and_call_original

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

    with_event_machine(:timeout => 1) do
      # Hack to not have the test take too long because heartbeat interval is defined
      # as an Integer in the schema.
      bootstrap.config['intervals']['heartbeat'] = 0.01

      bootstrap.setup
      bootstrap.start

      # Register instances
      5.times do |ii|
        instance = create_and_register_instance(bootstrap,
                                                "cc_partition"        => "partition",
                                                "application_id"      => ii,
                                                "application_version" => ii,
                                                "instance_index"      => ii)
        instance.state = Dea::Instance::State::RUNNING
        instances << instance
      end
    end

    expect(heartbeats.size).to eq(instances.size)
    instances.size.times do |ii|
      expect(heartbeats[ii].has_key?("dea")).to be true
      expect(heartbeats[ii]["droplets"].size).to eq((instances.size - ii))

      # Check that we received the correct heartbeats
      heartbeats[ii]["droplets"].each_with_index do |hb, jj|
        verify_instance_heartbeat(hb, instances[ii + jj])
      end
    end
  end

  describe "instance state filtering" do
    def run
      heartbeat = nil
      nats_mock.subscribe("dea.heartbeat") do |msg, _|
        heartbeat = Yajl::Parser.parse(msg)
        done
      end

      with_event_machine(:timeout => 1) do
        bootstrap.setup
        yield
        bootstrap.start
      end

      heartbeat
    end

    matching_states = [
      Dea::Instance::State::STARTING,
      Dea::Instance::State::RUNNING,
      Dea::Instance::State::CRASHED,
      Dea::Instance::State::EVACUATING,
    ]

    Dea::Instance::State.constants.map do |constant|
      Dea::Instance::State.const_get(constant)
    end.each do |state|
      if matching_states.include?(state)
        it "should include #{state.inspect}" do
          allow(bootstrap).to receive(:start_finish).and_call_original

          heartbeat = run do
            instance = create_and_register_instance(bootstrap)
            instance.state = state
          end

          expect(heartbeat).to_not be_nil, "expected #{state} to be included in heartbeat"
        end
      else
        it "should exclude #{state.inspect}" do
          allow(bootstrap).to receive(:start_finish).and_call_original

          heartbeat = run do
            instance = create_and_register_instance(bootstrap)
            instance.state = state
          end

          expect(heartbeat["droplets"]).to be_empty, "expected #{state} not to be included in heartbeat"
        end
      end
    end
  end

  def verify_instance_heartbeat(hb, instance)
    hb_keys = %w[cc_partition droplet version instance index state state_timestamp]
    expect(hb.keys).to eq(hb_keys)
    expect(hb["cc_partition"]).to eq(instance.cc_partition)
    expect(hb["droplet"]).to eq(instance.application_id)
    expect(hb["version"]).to eq(instance.application_version)
    expect(hb["instance"]).to eq(instance.instance_id)
    expect(hb["index"]).to eq(instance.instance_index)
    expect(hb["state"]).to eq(instance.state)
  end
end
