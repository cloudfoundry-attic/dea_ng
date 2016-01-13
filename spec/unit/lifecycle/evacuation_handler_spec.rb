require "spec_helper"
require "dea/bootstrap"

describe EvacuationHandler do
  def instance_with_state(state)
    Dea::Instance.new(terrible_bootstrap, valid_instance_attributes).tap do |instance|
      instance.state = state
    end
  end

  let(:terrible_bootstrap) { double(:bootstrap, config: {}) }

  let(:message_bus) do
    bus = double(:message_bus)
    @published_messages = {}
    allow(bus).to receive(:publish) do |subject, message|
      @published_messages[subject] ||= []
      @published_messages[subject] << message
    end
    bus
  end

  let(:locator_responders) do
    [
      double(:stager_advertiser, stop: nil),
      double(:dea_advertiser, stop: nil)
    ]
  end

  let(:logger) { double(:logger, error: nil, info: nil) }

  let(:instance_registry) { Dea::InstanceRegistry.new({}) }
  let(:instances) do
    {
      born: instance_with_state(Dea::Instance::State::BORN),
      starting: instance_with_state(Dea::Instance::State::STARTING),
      resuming: instance_with_state(Dea::Instance::State::RESUMING),
      running: instance_with_state(Dea::Instance::State::RUNNING),
      stopping: instance_with_state(Dea::Instance::State::STOPPING),
      stopped: instance_with_state(Dea::Instance::State::STOPPED),
      crashed: instance_with_state(Dea::Instance::State::CRASHED),
      evacuating: instance_with_state(Dea::Instance::State::EVACUATING)
    }
  end

  let(:goodbye_message) { "bye bye dea" }

  let(:config) do
    { "evacuation_bail_out_time_in_seconds" => 15 * 60 }
  end

  subject(:handler) do
    EvacuationHandler.new(message_bus, locator_responders, instance_registry, logger, config)
  end

  context "before the evacuation handler is called" do
    it { should_not be_evacuating }
  end

  context "when the evacuation handler is called for the first time" do
    it "is evacuating" do
      handler.evacuate!(goodbye_message)
      expect(handler).to be_evacuating
    end

    it "sends the shutdown message" do
      handler.evacuate!(goodbye_message)
      expect(@published_messages["dea.shutdown"]).to include goodbye_message
    end

    it "stops advertising" do
      locator_responders.each do |locator|
        expect(locator).to receive(:stop)
      end

      handler.evacuate!(goodbye_message)
    end

    it "sends a heartbeat (since there is no need to wait for the timer)"

    context "with a mixture of instances in various states" do
      before { instances.each { |_, instance| instance_registry.register instance } }

      it "sends the exit message for all born/starting/running/resuming instances (will be removed when deterministic evacuation is complete)" do
        handler.evacuate!(goodbye_message)

        messages = @published_messages["droplet.exited"]
        expected_instance_ids = [instances[:born], instances[:starting], instances[:resuming], instances[:running]].map(&:instance_id)
        published_instance_ids = messages.map { |m| m["instance"] }

        expect(messages).to have(4).items
        expect(published_instance_ids).to match_array expected_instance_ids
        expect(messages.map { |m| m["reason"] }.uniq).to eq ["DEA_EVACUATION"]
      end

      it "transitions born/running/starting/resuming instances to evacuating" do
        handler.evacuate!(goodbye_message)

        expect(instances[:born]).to be_evacuating
        expect(instances[:starting]).to be_evacuating
        expect(instances[:resuming]).to be_evacuating
        expect(instances[:running]).to be_evacuating

        expect(instances[:evacuating]).to be_evacuating
      end

      it "returns false" do
        expect(handler.evacuate!(goodbye_message)).to eq false
      end
    end

    context "with all instances either stopping/stopped/crashed" do
      before do
        instance_registry.register(instances[:stopping])
        instance_registry.register(instances[:stopped])
        instance_registry.register(instances[:crashed])
      end

      it "does not transition instances" do
        handler.evacuate!(goodbye_message)

        expect(instances[:stopping]).to be_stopping
        expect(instances[:stopped]).to be_stopped
        expect(instances[:crashed]).to be_crashed
      end

      it "returns true" do
        expect(handler.evacuate!(goodbye_message)).to eq true
      end
    end

    context "when the dea has no instances" do
      it "returns true" do
        expect(handler.evacuate!(goodbye_message)).to eq true
      end
    end

    context "and its called again" do
      let(:now) { Time.new(2012, 11, 10, 8, 30) }

      before do
        Timecop.freeze now do
          handler.evacuate!(goodbye_message)
        end
        @published_messages = {}
      end

      it "does not send the shutdown message" do
        handler.evacuate!(goodbye_message)
        expect(@published_messages["dea.shutdown"]).to be_nil
      end

      it "does not send a heartbeat" do

      end

      context "and the registry still has evacuating instances" do
        before do
          instance_registry.register(instances[:evacuating])
        end

        it "returns false (the dea should not be stopped yet)" do
          Timecop.travel now + 10.minutes do
            expect(handler.evacuate!(goodbye_message)).to eq false
          end
        end

        it "logs nothing" do
          expect(logger).to_not receive(:error)
          handler.evacuate!(goodbye_message)
        end

        it "should not send exit messages" do
          handler.evacuate!(goodbye_message)
          expect(@published_messages["droplet.exited"]).to be_nil
        end

        context "and the time elapsed since the first call is greater than the configured time" do
          it "returns true" do
            Timecop.travel now + 15.minutes do
              expect(handler.evacuate!(goodbye_message)).to eq true
            end
          end
        end
      end

      context "and the registry (somehow) has born/starting/resuming/running instances" do
        before do
          instance_registry.register(instances[:born])
          instance_registry.register(instances[:starting])
          instance_registry.register(instances[:resuming])
          instance_registry.register(instances[:running])
        end

        it "should send exit messages" do
          handler.evacuate!(goodbye_message)
          expect(@published_messages["droplet.exited"]).to have(4).items
        end

        it "transitions any lagging instances to evacuating (we presume this should never happen)" do
          handler.evacuate!(goodbye_message)

          expect(instances[:born]).to be_evacuating
          expect(instances[:starting]).to be_evacuating
          expect(instances[:resuming]).to be_evacuating
          expect(instances[:running]).to be_evacuating
        end

        it "logs this faulty state" do
          expect(logger).to receive(:error).with(/found an unexpected/i).exactly(4).times
          handler.evacuate!(goodbye_message)
        end

        it "returns false (the dea should not be stopped yet)" do
          Timecop.travel now + 10.minutes do
            expect(handler.evacuate!(goodbye_message)).to eq false
          end
        end
      end
    end
  end
end