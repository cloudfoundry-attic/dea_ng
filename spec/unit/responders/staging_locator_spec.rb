require "spec_helper"
require "dea/nats"
require "dea/config"
require "dea/resource_manager"

require "dea/starting/instance_registry"

require "dea/staging/staging_task_registry"

require "dea/responders/staging_locator"

describe Dea::Responders::StagingLocator do
  stub_nats

  let(:nats) { Dea::Nats.new(bootstrap, config) }
  let(:bootstrap) { double(:bootstrap, :config => config) }
  let(:dea_id) { "unique-dea-id" }
  let(:instance_registry) { Dea::InstanceRegistry.new }
  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }
  let(:resource_manager) { Dea::ResourceManager.new(instance_registry, staging_task_registry) }
  let(:config) { Dea::Config.new({}) }

  subject { described_class.new(nats, dea_id, resource_manager, config) }

  describe "#start" do
    describe "subscription for 'staging.locate'" do
      before { EM.stub(:add_periodic_timer) }

      it "subscribes to 'staging.locate' message" do
        subject.start
        subject.should_receive(:advertise)
        nats_mock.publish("staging.locate")
      end

      it "subscribes to locate message but manually tracks the subscription" do
        nats.should_receive(:subscribe).
          with("staging.locate", hash_including(:do_not_track_subscription => true))
        subject.start
      end
    end

    describe "periodic 'staging.advertise'" do
      context "when intervals.advertise config is set" do
        before { config["intervals"] = {"advertise" => 2} }
        it "starts sending 'staging.advertise' every 2 secs" do
          EM.should_receive(:add_periodic_timer).with(2).and_yield
          nats.should_receive(:publish).with("staging.advertise", kind_of(Hash))
          subject.start
        end
      end

      context "when intervals.advertise config is not set" do
        before { config["intervals"] = {} }
        it "starts sending 'staging.advertise' every 5 secs" do
          EM.should_receive(:add_periodic_timer).with(5).and_yield
          nats.should_receive(:publish).with("staging.advertise", kind_of(Hash))
          subject.start
        end
      end
    end
  end

  describe "#stop" do
    context "when subscription was made" do
      it "unsubscribes from 'staging.locate' message" do
        EM.stub(:add_periodic_timer)
        subject.start

        subject.should_receive(:advertise) # sanity check
        nats_mock.publish("staging.locate")

        subject.stop
        subject.should_not_receive(:advertise)
        nats_mock.publish("staging.locate")
      end

      it "stops sending 'staging.advertise' periodically" do
        a_timer = 'advertise timer'
        EM.stub(:add_periodic_timer).and_return(a_timer)
        subject.start
        EM.should_receive(:cancel_timer).with(a_timer)
        nats.should_not_receive(:publish).with('staging.advertise', anything)
        subject.stop
      end
    end

    context "when subscription was not made" do
      it "does not unsubscribe" do
        nats.should_not_receive(:unsubscribe)
        subject.stop
      end

      it "stops sending 'staging.advertise' periodically" do
        subject.stop # does not blow up
      end
    end
  end

  describe "#advertise" do
    it "publishes 'staging.advertise' message" do
      config["stacks"] = ["lucid64"]
      resource_manager.stub(:remaining_memory => 45678)
      resource_manager.stub(:remaining_disk => 12345)

      nats_mock.should_receive(:publish).with("staging.advertise", JSON.dump(
        "id" => dea_id,
        "stacks" => ["lucid64"],
        "available_memory" => 45678,
        "available_disk" => 12345,
      ))
      subject.advertise
    end

    context "when a failure happens" do
      it "catches the error since this is the top level" do
        config["stacks"] = ["lucid64"]
        resource_manager.stub(:remaining_memory => 45678)

        nats_mock.stub(:publish).and_raise(RuntimeError, "somethingTerrible")
        expect{subject.advertise}.not_to raise_error
      end
    end
  end
end
