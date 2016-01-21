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
    describe "periodic 'staging.advertise'" do
      context "when intervals.advertise config is set" do
        before { config["intervals"] = {"advertise" => 2} }
        it "starts sending 'staging.advertise' every 2 secs" do
          allow(EM).to receive(:add_periodic_timer).with(2).and_yield
          allow(nats).to receive(:publish).with("staging.advertise", kind_of(Hash))
          subject.start
        end
      end

      context "when intervals.advertise config is not set" do
        before { config["intervals"] = {} }
        it "starts sending 'staging.advertise' every 5 secs" do
          allow(EM).to receive(:add_periodic_timer).with(5).and_yield
          allow(nats).to receive(:publish).with("staging.advertise", kind_of(Hash))
          subject.start
        end
      end
    end
  end

  describe "#stop" do
    context "when subscription was made" do
      it "stops sending 'staging.advertise' periodically" do
        a_timer = 'advertise timer'
        allow(EM).to receive(:add_periodic_timer).and_return(a_timer)
        subject.start
        allow(EM).to receive(:cancel_timer).with(a_timer)
        expect(nats).to_not receive(:publish).with('staging.advertise', anything)
        subject.stop
      end
    end

    context "when subscription was not made" do
      it "does not unsubscribe" do
        expect(nats).to_not receive(:unsubscribe)
        subject.stop
      end

      it "stops sending 'staging.advertise' periodically" do
        subject.stop # does not blow up
      end
    end
  end

  describe "#advertise" do
    it "publishes 'staging.advertise' message" do
      config["stacks"] = [{"name" => "cflinuxfs2"}]
      allow(resource_manager).to receive(:remaining_memory).and_return(45678)
      allow(resource_manager).to receive(:remaining_disk).and_return(12345)

      allow(nats_mock).to receive(:publish).with("staging.advertise", JSON.dump(
        "id" => dea_id,
        "stacks" => ["cflinuxfs2"],
        "available_memory" => 45678,
        "available_disk" => 12345,
      ))
      subject.advertise
    end

    context "when a failure happens" do
      it "catches the error since this is the top level" do
        config["stacks"] = [{"name" => "cflinuxfs2"}]
        allow(resource_manager).to receive(:remaining_memory).and_return(45678)

        allow(nats_mock).to receive(:publish).and_raise(RuntimeError, "somethingTerrible")
        expect{subject.advertise}.not_to raise_error
      end
    end
  end
end
