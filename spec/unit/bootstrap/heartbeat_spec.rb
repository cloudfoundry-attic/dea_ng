# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea, :order => :defined do
  include_context "bootstrap_setup"
  let(:port) {25432}

  it "should periodically send out heartbeats on 'dea.heartbeat' for all instances" do
    allow(bootstrap).to receive(:setup_sweepers).and_call_original
    allow(bootstrap).to receive(:setup_hm9000).and_call_original

    # the bootstrap is never actually setup and so we need to mock out these calls
    allow(bootstrap).to receive(:reap_unreferenced_droplets)
    allow(bootstrap).to receive(:reap_orphaned_containers)

    instances = []
    heartbeats = []

    with_event_machine(:timeout => 1) do

      # Unregister an instance with each heartbeat received
      http_server =
          Thin::Server.new('0.0.0.0', port, lambda { |env|
            heartbeats << Yajl::Parser.parse(env['rack.input'])
            if heartbeats.size == 5 
              done
            else
              bootstrap.instance_registry.unregister(instances[heartbeats.size-1])
            end
            [202, {}, ''] }, { signals: false })

        http_server.ssl = true
        http_server.ssl_options = {
          private_key_file: fixture("/certs/hm9000_server.key"),
          cert_chain_file: fixture("/certs/hm9000_server.crt"),
          verify_peer: true,
        }

      http_server.start

      # Hack to not have the test take too long because heartbeat interval is defined
      # as an Integer in the schema.
      bootstrap.config['intervals']['heartbeat'] = 0.1

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
    def run(port=25432)

      heartbeat = ""
      with_event_machine(:timeout => 1) do
        http_server =
          Thin::Server.new('0.0.0.0', port, lambda { |env|
            heartbeat = Yajl::Parser.parse(env['rack.input'])
            done
            [202, {}, ''] }, { signals: false })

        http_server.ssl = true
        http_server.ssl_options = {
          private_key_file: fixture("/certs/hm9000_server.key"),
          cert_chain_file: fixture("/certs/hm9000_server.crt"),
          verify_peer: true,
        }

        http_server.start
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
    end.each_with_index do |state, index|
      if matching_states.include?(state)
        it "should include #{state.inspect}" do
          allow(bootstrap).to receive(:start_finish).and_call_original

          bootstrap.config['hm9000']['listener_uri'] = "https://127.0.0.1:#{port+index+5}"

          heartbeat = run(port+index+5) do
            expect(bootstrap.instance_registry.size).to eq(0)
            instance = create_and_register_instance(bootstrap)
            instance.state = state
          end

          expect(heartbeat["dea"]).to eq(bootstrap.uuid)
          expect(heartbeat).to_not be_empty
          expect(heartbeat["droplets"][0]["state"]).to eq(state), "expected #{state} to be included in heartbeat"
        end
      else
        it "should exclude #{state.inspect}" do
          allow(bootstrap).to receive(:start_finish).and_call_original

          bootstrap.config['hm9000']['listener_uri'] = "https://127.0.0.1:#{port+index+5}"

          heartbeat = run(port+index+5) do
            expect(bootstrap.instance_registry.size).to eq(0)
            instance = create_and_register_instance(bootstrap)
            instance.state = state
          end
          
          expect(heartbeat["dea"]).to eq(bootstrap.uuid)
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
