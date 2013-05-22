# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe "Dea::Bootstrap#handle_dea_stop" do
  include_context "bootstrap_setup"

  def publish(message = {})
    em do
      bootstrap.setup
      bootstrap.start

      nats_mock.publish("dea.stop", message)

      EM.next_tick do
        done
      end
    end
  end

  let(:instance_mock) do
    instance = bootstrap.create_instance(valid_instance_attributes)
    instance.state = Dea::Instance::State::RUNNING
    instance
  end

  let(:resource_manager) do
    manager = double(:resource_manager)
    manager.stub(:could_reserve?).and_return(true)
    manager
  end

  before do
    bootstrap.unstub(:setup_router_client)
    bootstrap.setup

    Dea::Instance.any_instance.stub(:setup_link)
    bootstrap.stub(:resource_manager).and_return(resource_manager)
    bootstrap.stub(:instances_filtered_by_message).and_yield(instance_mock)

    instance_mock.stub(:running?).and_return(true)
    instance_mock.stub(:promise_stop).and_return(delivering_promise)
    instance_mock.stub(:destroy)
  end

  describe "filtering" do
    before do
      bootstrap.stub(:instances_filtered_by_message) do
        EM.next_tick do
          done
        end
      end.and_yield(instance_mock)
    end

    it "skips instances that are not running" do
      instance_mock.stub(:running?).and_return(false)
      instance_mock.should_not_receive(:stop)

      publish
    end

    it "stops instances that are running" do
      instance_mock.stub(:running?).and_return(true)
      instance_mock.should_receive(:stop)

      publish
    end
  end

  it "unregisters with the router" do
    sent_router_unregister = false
    nats_mock.subscribe("router.unregister") do
      sent_router_unregister = true
      EM.stop
    end

    publish

    sent_router_unregister.should be_true
  end

  it "send exited notifications" do
    sent_exited_notification = false
    nats_mock.subscribe("droplet.exited") do
      sent_exited_notification = true
      EM.stop
    end

    publish

    sent_exited_notification.should be_true
  end

  describe "when stop completes" do
    before do
      instance_mock.stub(:running?).and_return(true)

      bootstrap.stub(:instances_filtered_by_message) do
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
