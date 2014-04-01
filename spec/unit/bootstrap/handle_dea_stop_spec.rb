# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe "Dea::Bootstrap#handle_dea_stop" do
  include_context "bootstrap_setup"

  def publish(message = {})
    with_event_machine do
      bootstrap.setup
      bootstrap.start

      nats_mock.publish("dea.stop", message)

      EM.next_tick do
        done
      end
    end
  end

  let(:instance_mock) { bootstrap.instance_manager.create_instance(valid_instance_attributes) }

  let(:resource_manager) do
    manager = double(:resource_manager)
    manager.stub(:could_reserve?).and_return(true)
    manager.stub(:number_reservable).and_return(123)
    manager
  end

  let(:instance_registry) { double(:instance_registry, :register => nil, :unregister => nil) }

  before do
    bootstrap.unstub(:setup_router_client)
    with_event_machine do
      bootstrap.setup
      done
    end

    Dea::Instance.any_instance.stub(:setup_link)
    Dea::Responders::DeaLocator.any_instance.stub(:start) # to deal with test pollution
    bootstrap.stub(:resource_manager).and_return(resource_manager)
    bootstrap.stub(:instance_registry).and_return(instance_registry)

    instance_registry.stub(:instances_filtered_by_message).and_yield(instance_mock)
    instance_mock.stub(:promise_stop).and_return(delivering_promise)
    instance_mock.stub(:destroy)
  end

  describe "filtering" do
    before do
      instance_registry.stub(:instances_filtered_by_message) do
        EM.next_tick do
          done
        end
      end.and_yield(instance_mock)
    end

    it "skips instances that are not running" do
      instance_mock.state = Dea::Instance::State::STOPPED
      instance_mock.should_not_receive(:stop)

      publish
    end

    def self.it_stops_the_instance
      it "stops the instance" do
        instance_mock.should_receive(:stop)

        publish
      end
    end

    def self.it_unregisters_with_the_router
      it "unregisters with the router" do
        sent_router_unregister = false
        nats_mock.subscribe("router.unregister") do
          sent_router_unregister = true
          EM.stop
        end

        publish

        sent_router_unregister.should be_true
      end
    end

    context "when the app is starting" do
      before { instance_mock.state = Dea::Instance::State::STARTING }

      it_stops_the_instance
    end

    context "when the app is running" do
      before { instance_mock.state = Dea::Instance::State::RUNNING }

      it_stops_the_instance
      it_unregisters_with_the_router
    end

    context "when the app is evacuating" do
      before { instance_mock.state = Dea::Instance::State::EVACUATING }

      it_stops_the_instance
      it_unregisters_with_the_router
    end
  end

  describe "when stop completes" do
    before do
      instance_mock.stub(:running?).and_return(true)

      instance_registry.stub(:instances_filtered_by_message) do
        EM.next_tick do
          done
        end
      end.and_yield(instance_mock)
    end

    describe "with failure" do
      before do
        instance_mock.stub(:stop).and_yield(RuntimeError.new("Error"))
      end

      it "works" do
        publish
      end
    end

    describe "with success" do
      before do
        instance_mock.stub(:stop).and_yield(nil)
      end

      it "works" do
        publish
      end
    end
  end
end
