require "spec_helper"
require "dea/nats"
require "dea/instance_registry"
require "dea/staging_task_registry"
require "dea/resource_manager"
require "dea/responders/dea_locator"
require "dea/config"

describe Dea::Responders::DeaLocator do
  stub_nats

  let(:nats) { Dea::Nats.new(bootstrap, config) }
  let(:bootstrap) { mock(:bootstrap, :config => config) }
  let(:dea_id) { "unique-dea-id" }
  let(:instance_registry) do
    instance_registry = nil
    if !EM.reactor_running?
      em do
        instance_registry = Dea::InstanceRegistry.new
        done
      end
    else
      instance_registry = Dea::InstanceRegistry.new
    end
    instance_registry
  end
  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }
  let(:resource_manager) { Dea::ResourceManager.new(instance_registry, staging_task_registry) }
  let(:config) { Dea::Config.new({}) }

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
          .with("dea.locate", hash_including(:do_not_track_subscription => true))
        subject.start
      end
    end

    describe "periodic 'dea.advertise'" do
      def self.it_sends_periodic_dea_advertise(expected_interval)
        it "starts sending 'dea.advertise' every X secs" do
          # Wait twice as long as expected interval
          # to be able to expect that we receive two messages
          max_run_length = expected_interval * 2
          messages_published = []

          em(:timeout => max_run_length+0.2) do
            EM.add_timer(max_run_length+0.1) { EM.stop }
            nats_mock.subscribe("dea.advertise") do |msg|
              messages_published << msg
            end
            subject.start
          end

          messages_published.size.should == 2
        end
      end

      context "when intervals.advertise config is set" do
        before { config["intervals"] = {"advertise" => 2} }
        it_sends_periodic_dea_advertise(2)
      end

      context "when intervals.advertise config is not set" do
        before { config["intervals"] = {} }
        it_sends_periodic_dea_advertise(5)
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
        config["intervals"] = {"advertise" => 2}
        max_run_length = 2 * 2
        messages_published = []

        em(:timeout => max_run_length+0.2) do
          EM.add_timer(max_run_length+0.1) { EM.stop }
          nats_mock.subscribe("dea.advertise") do |msg|
            messages_published << msg
            subject.stop
          end
          subject.start
        end

        messages_published.size.should == 1
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
    let(:available_memory) { 45678 }
    before do
      resource_manager.stub(:app_id_to_count => {
        "app_id_1" => 1,
        "app_id_2" => 3
      })
      resource_manager.stub(:remaining_memory => available_memory)
    end

    context "when config specifies that dea is for prod-only apps" do
      before { config["only_production_apps"] = true }

      it "publishes 'dea.advertise' message" do
        nats_mock.should_receive(:publish).with("dea.advertise", JSON.dump(
          "id" => dea_id,
          "prod" => true,
          "stacks" => [],
          "available_memory" => available_memory,
          "app_id_to_count" => {
            "app_id_1" => 1,
            "app_id_2" => 3
          }
        ))
        subject.advertise
      end
    end

    context "when config specifies that dea is not prod-only apps" do
      before { config["only_production_apps"] = false }

      it "publishes 'dea.advertise' message" do
        nats_mock.should_receive(:publish).with("dea.advertise", JSON.dump(
          "id" => dea_id,
          "prod" => false,
          "stacks" => [],
          "available_memory" => available_memory,
          "app_id_to_count" => {
            "app_id_1" => 1,
            "app_id_2" => 3
          }
        ))
        subject.advertise
      end
    end

    context "when config specifies stacks" do
      before { config["stacks"] = ["stack-1", "stack-2"] }

      it "publishes 'dea.advertise' message with stacks" do
        nats_mock.should_receive(:publish).with("dea.advertise", JSON.dump(
          "id" => dea_id,
          "prod" => false,
          "stacks" => ["stack-1", "stack-2"],
          "available_memory" => available_memory,
          "app_id_to_count" => {
            "app_id_1" => 1,
            "app_id_2" => 3
          }
        ))
        subject.advertise
      end
    end
  end
end
