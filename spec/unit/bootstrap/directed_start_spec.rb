# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  describe "directed start" do
    def publish
      with_event_machine do
        bootstrap.setup
        bootstrap.start

        nats_mock.publish("dea.#{bootstrap.uuid}.start", valid_instance_attributes)

        EM.next_tick do
          done
        end
      end
    end

    attr_reader :instance_mock

    let(:resource_manager) { double(:resource_manager, :could_reserve? => true, :remaining_memory => nil, :remaining_disk => nil, :app_id_to_count => {}) }

    before do
      bootstrap.stub(:resource_manager).and_return(resource_manager)

      @instance_mock = Dea::Instance.new(bootstrap, valid_instance_attributes)
      @instance_mock.stub(:validate)
      @instance_mock.stub(:start) do
        @instance_mock.state = Dea::Instance::State::STARTING
        @instance_mock.state = Dea::Instance::State::RUNNING
      end

      Dea::Instance.should_receive(:new).and_return(@instance_mock)

      bootstrap.unstub(:setup_router_client)
    end

    it "doesn't call #start when the instance is invalid" do
      instance_mock.should_receive(:validate).and_raise("Validation error")
      instance_mock.should_not_receive(:start)

      publish
    end

    it "calls #start" do
      instance_mock.should_receive(:validate)
      instance_mock.should_receive(:start)

      publish
    end

    describe "when start completes" do
      describe "with failure" do
        before do
          instance_mock.stub(:start) do
            instance_mock.state = Dea::Instance::State::STARTING
            instance_mock.state = Dea::Instance::State::CRASHED
          end
        end

        it "does not publish a heartbeat" do
          received_heartbeat = false
          nats_mock.subscribe("dea.heartbeat") do
            received_heartbeat = true
          end

          publish

          received_heartbeat.should be_false
        end

        it "does not register with router" do
          sent_router_register = false
          nats_mock.subscribe("router.register") do
            sent_router_register = true
          end

          publish

          sent_router_register.should be_false
        end

        it "should be registered with the instance registry" do
          publish

          bootstrap.instance_registry.should_not be_empty
        end
      end

      describe "with success" do
        before do
          instance_mock.stub(:start) do
            instance_mock.state = Dea::Instance::State::STARTING
            instance_mock.state = Dea::Instance::State::RUNNING
          end
        end

        it "publishes a heartbeat" do
          received_heartbeat = false
          nats_mock.subscribe("dea.heartbeat") do
            received_heartbeat = true
          end

          publish

          received_heartbeat.should be_true
        end

        it "registers with the router" do
          sent_router_register = false
          nats_mock.subscribe("router.register") do
            sent_router_register = true
          end

          publish

          sent_router_register.should be_true
        end

        it "should be registered with the instance registry" do
          publish

          bootstrap.instance_registry.should_not be_empty
        end
      end
    end
  end
end
