# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  describe "directed start" do
    def publish
      em do
        bootstrap.setup
        bootstrap.start

        nats_mock.publish("dea.#{bootstrap.uuid}.start", {})
      end
    end

    attr_reader :instance_mock

    before do
      @instance_mock = Dea::Instance.new(bootstrap, valid_instance_attributes)
      @instance_mock.stub(:validate)
      @instance_mock.stub(:start)

      Dea::Instance.should_receive(:new).and_return(@instance_mock)
    end

    it "should not #start when the instance is invalid" do
      instance_mock.should_receive(:validate) do
        EM.next_tick do
          done
        end

        raise "Validation error"
      end

      instance_mock.should_not_receive(:start)

      publish
    end


    it "should #start when the instance is valid" do
      instance_mock.should_receive(:validate) do
        EM.next_tick do
          done
        end
      end

      instance_mock.should_receive(:start)

      publish
    end

    describe "when start completes" do
      before do
        bootstrap.unstub(:setup_router_client)
      end

      it "does nothing when an error occured" do
        received_heartbeat = false
        nats_mock.subscribe("dea.heartbeat") do
          received_heartbeat = true
        end

        # Almost done when #start is called
        instance_mock.should_receive(:start) do
          EM.next_tick { done }
        end.and_yield(RuntimeError.new("Error"))

        publish

        received_heartbeat.should be_false
      end

      describe "successfully" do
        before do
          # Almost done when #start is called
          instance_mock.should_receive(:start) do
            EM.next_tick { done }
          end.and_yield(nil)
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

        it "registers with the instance registry" do
          publish

          bootstrap.instance_registry.should_not be_empty
        end
      end
    end
  end
end
