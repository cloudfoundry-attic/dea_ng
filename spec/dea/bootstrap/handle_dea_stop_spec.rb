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
    end
  end

  let(:instance_mock) do
    Dea::Instance.new(bootstrap, valid_instance_attributes)
  end

  before do
    bootstrap.unstub(:setup_router_client)

    # Almost done when #instances_filtered_by_message is called
    bootstrap.stub(:instances_filtered_by_message) do
      EM.next_tick do
        done
      end
    end.and_yield(instance_mock)

    instance_mock.stub(:running?).and_return(true)
    instance_mock.stub(:stop)
  end

  describe "filtering" do
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

  describe "when stop completes" do
    before do
      instance_mock.stub(:running?).and_return(true)
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
