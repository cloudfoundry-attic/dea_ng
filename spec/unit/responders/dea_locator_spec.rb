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
  let(:url) { 'https://host:port' }
  let(:instance_registry) { instance_registry = Dea::InstanceRegistry.new }
  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }
  let(:resource_manager) { Dea::ResourceManager.new(instance_registry, staging_task_registry) }
  let(:config) { Dea::Config.new(config_overrides) }
  let(:config_overrides) { {} }

  subject { described_class.new(nats, dea_id, resource_manager, config, url) }

  describe "#start" do
    describe "periodic 'dea.advertise'" do
      context "when intervals.advertise config is set" do
        let(:config_overrides) { {"intervals" => { "advertise" => 2 } } }

        it "starts sending 'dea.advertise' every 2 secs" do
          allow(EM).to receive(:add_periodic_timer).with(2).and_yield
          expect(nats).to receive(:publish).with("dea.advertise", kind_of(Hash))
          subject.start
        end
      end

      context "when intervals.advertise config is not set" do
        let(:config_overrides) { {"intervals" => { } } }

        it "starts sending 'dea.advertise' every 5 secs" do
          allow(EM).to receive(:add_periodic_timer).with(5).and_yield
          expect(nats).to receive(:publish).with("dea.advertise", kind_of(Hash))
          subject.start
        end
      end
    end
  end

  describe "#stop" do
    context "when subscription was made" do
      it "stops sending 'dea.advertise' periodically" do
        a_timer = 'dea advertise timer'
        allow(EM).to receive(:add_periodic_timer).and_return a_timer
        subject.start
        expect(EM).to receive(:cancel_timer).with(a_timer)
        subject.stop
      end
    end

    context "when subscription was not made" do
      it "does not unsubscribe" do
        expect(nats).to_not receive(:unsubscribe)
        subject.stop
      end

      it "stops sending 'dea.advertise' periodically" do
        subject.stop # does not blow up
      end
    end
  end

  describe "#advertise" do
    let(:config_overrides) { { "stacks" => [{"name" =>"stack-1"},{"name" =>"stack-2"}] } }
    let(:available_disk) { 12345 }
    let(:available_memory) { 45678 }
    before do
      allow(resource_manager).to receive(:app_id_to_count).and_return({
        "app_id_1" => 1,
        "app_id_2" => 3
      })
      allow(resource_manager).to receive(:remaining_memory).and_return(available_memory)
      allow(resource_manager).to receive(:remaining_disk).and_return(available_disk)
    end

    it "publishes 'dea.advertise' message" do
      expect(nats).to receive(:publish).with(
        "dea.advertise",
        { "id" => dea_id,
          "url" => url,
          "stacks" => ["stack-1", "stack-2"],
          "available_memory" => available_memory,
          "available_disk" => available_disk,
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
        allow(nats).to receive(:publish).and_raise(RuntimeError, "Something terrible happened")

        expect { subject.advertise }.to_not raise_error
      end
    end
  end
end
