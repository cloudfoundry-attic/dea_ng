require "spec_helper"
require "dea/nats"
require "dea/starting/instance_registry"
require "dea/resource_manager"
require "dea/responders/dea_locator"
require "dea/config"

require "dea/staging/staging_task_registry"

describe Dea::Responders::DeaLocator do
  stub_nats

  let(:nats) { Dea::Nats.new(bootstrap, config) }
  let(:bootstrap) { double(:bootstrap, :config => config) }
  let(:dea_id) { "unique-dea-id" }
  let(:instance_registry) { instance_registry = Dea::InstanceRegistry.new }
  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }
  let(:resource_manager) { Dea::ResourceManager.new(instance_registry, staging_task_registry) }
  let(:config) { Dea::Config.new(config_overrides) }
  let(:config_overrides) { {} }

  subject { described_class.new(nats, dea_id, resource_manager, config) }

  describe "#start" do
    describe "subscription for 'dea.locate'" do
      before { EM.stub(:add_periodic_timer) }

      it "subscribes to 'dea.locate' message" do
        subject.start
        subject.should_receive(:advertise)
        nats_mock.publish("dea.locate")
      end

      it "subscribes to locate message but manually tracks the subscription" do
        nats
        .should_receive(:subscribe)
        .with("dea.locate", hash_including(do_not_track_subscription: true))
        subject.start
      end
    end

    describe "periodic 'dea.advertise'" do
      context "when intervals.advertise config is set" do
        let(:config_overrides) { {"intervals" => { "advertise" => 2 } } }

        it "starts sending 'dea.advertise' every 2 secs" do
          EM.should_receive(:add_periodic_timer).with(2).and_yield
          nats.should_receive(:publish).with("dea.advertise", kind_of(Hash))
          subject.start
        end
      end

      context "when intervals.advertise config is not set" do
        let(:config_overrides) { {"intervals" => { } } }

        it "starts sending 'dea.advertise' every 5 secs" do
          EM.should_receive(:add_periodic_timer).with(5).and_yield
          nats.should_receive(:publish).with("dea.advertise", kind_of(Hash))
          subject.start
        end
      end
    end
  end

  describe "#stop" do
    context "when subscription was made" do
      it "unsubscribes from 'dea.locate' message" do
        EM.stub(:add_periodic_timer)
        subject.start

        subject.should_receive(:advertise) # sanity check
        nats_mock.publish("dea.locate")

        subject.stop
        subject.should_not_receive(:advertise)
        nats_mock.publish("dea.locate")
      end

      it "stops sending 'dea.advertise' periodically" do
        a_timer = 'dea advertise timer'
        EM.stub(:add_periodic_timer).and_return a_timer
        subject.start
        EM.should_receive(:cancel_timer).with(a_timer)
        subject.stop
      end
    end

    context "when subscription was not made" do
      it "does not unsubscribe" do
        nats.should_not_receive(:unsubscribe)
        subject.stop
      end

      it "stops sending 'dea.advertise' periodically" do
        subject.stop # does not blow up
      end
    end
  end

  describe "#advertise" do
    let(:config_overrides) { { "stacks" => ["stack-1", "stack-2"] } }
    let(:available_disk) { 12345 }
    let(:available_memory) { 45678 }
    let(:available_instances) { 1 }
    before do
      resource_manager.stub(app_id_to_count: {
        "app_id_1" => 1,
        "app_id_2" => 3
      })
      resource_manager.stub(:remaining_memory => available_memory)
      resource_manager.stub(:remaining_disk => available_disk)
      resource_manager.stub(:remaining_instances => available_instances)
    end

    it "publishes 'dea.advertise' message" do
      nats.should_receive(:publish).with(
        "dea.advertise",
        { "id" => dea_id,
          "stacks" => ["stack-1", "stack-2"],
          "available_memory" => available_memory,
          "available_disk" => available_disk,
          "available_instances" => available_instances,
          "app_id_to_count" => {
            "app_id_1" => 1,
            "app_id_2" => 3
          },
          "placement_properties" => {
            "zone" => "default"
          }
        }
      )
      subject.advertise
    end

    context "when a failure happens" do
      it "should catch the error since this is the top level" do
        nats.stub(:publish).and_raise(RuntimeError, "Something terrible happened")

        expect { subject.advertise }.to_not raise_error
      end
    end
  end
end
