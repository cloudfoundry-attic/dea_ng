# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  describe "directed start" do
    def publish(next_tick=true)
      with_event_machine do
        bootstrap.setup
        bootstrap.start

        nats_mock.publish("dea.#{bootstrap.uuid}.start", valid_instance_attributes)

        if next_tick
          EM.next_tick do
            done
          end
        end
      end
    end

    attr_reader :instance_mock

    let(:resource_manager) { double(:resource_manager, :could_reserve? => true, :remaining_memory => nil, :remaining_disk => nil, :app_id_to_count => {}) }

    before do
      allow(bootstrap).to receive(:resource_manager).and_return(resource_manager)

      @instance_mock = Dea::Instance.new(bootstrap, valid_instance_attributes)
      allow(@instance_mock).to receive(:validate)
      allow(@instance_mock).to receive(:start) do
        @instance_mock.state = Dea::Instance::State::STARTING
        @instance_mock.state = Dea::Instance::State::RUNNING
      end

      allow(Dea::Instance).to receive(:new).and_return(@instance_mock)

      allow(bootstrap).to receive(:setup_router_client).and_call_original
    end

    it "doesn't call #start when the instance is invalid" do
      allow(instance_mock).to receive(:validate).and_raise("Validation error")
      expect(instance_mock).to_not receive(:start)

      publish
    end

    it "calls #start" do
      allow(instance_mock).to receive(:validate)
      allow(instance_mock).to receive(:start)

      publish
    end

    describe "when start completes" do
      describe "with failure" do
        before do
          allow(instance_mock).to receive(:start) do
            instance_mock.state = Dea::Instance::State::STARTING
            instance_mock.state = Dea::Instance::State::CRASHED
          end
        end

        it "does not publish a heartbeat" do
          received_heartbeat = false

          with_event_machine do
            start_http_server(25432) do |connection, data|
              received_heartbeat = true
            end

            publish
          end

          expect(received_heartbeat).to be false
        end

        it "does not register with router" do
          sent_router_register = false
          nats_mock.subscribe("router.register") do
            sent_router_register = true
          end

          publish

          expect(sent_router_register).to be false
        end

        it "should be registered with the instance registry" do
          publish

          expect(bootstrap.instance_registry).to_not be_empty
        end
      end

      describe "with success" do
        before do
          allow(instance_mock).to receive(:start) do
            instance_mock.state = Dea::Instance::State::STARTING
            instance_mock.state = Dea::Instance::State::RUNNING
          end
        end

        it "publishes a heartbeat" do
          received_heartbeat = false

          with_event_machine do
            start_http_server(25432) do |connection, data|
              received_heartbeat = true
              done
            end

            publish(false)
          end

          expect(received_heartbeat).to be true
        end

        it "registers with the router" do
          sent_router_register = false
          nats_mock.subscribe("router.register") do
            sent_router_register = true
          end

          publish

          expect(sent_router_register).to be true
        end

        it "should be registered with the instance registry" do
          publish

          expect(bootstrap.instance_registry).to_not be_empty
        end
      end
    end
  end
end
