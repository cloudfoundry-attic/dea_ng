require "spec_helper"
require "dea/bootstrap"
require "active_support/core_ext/numeric"

describe EvacuationHandler do
  def instance_with_state(state)
    Dea::Instance.new(terrible_bootstrap, valid_instance_attributes).tap do |instance|
      instance.state = state
    end
  end

  let(:terrible_bootstrap) { double(:bootstrap, config: {}, heartbeat_timer: "heartbeat_timer") }

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

  let(:staging_task_registry) { Dea::StagingTaskRegistry.new() }

  let(:goodbye_message) { "bye bye dea" }

  let(:config) do
    { "evacuation_bail_out_time_in_seconds" => 15 * 60 }
  end

  subject(:handler) do
    EvacuationHandler.new(terrible_bootstrap, message_bus, locator_responders, instance_registry, staging_task_registry, logger, config)
  end

  before do
    allow(terrible_bootstrap).to receive(:send_heartbeat)
    allow(EM).to receive(:cancel_timer)
  end

  context "before the evacuation handler is called" do
    it 'should not evacuate' do
      expect(handler).to_not be_evacuating
    end
  end

  it "sends a heartbeat of the evacuating instances" do
    expect(terrible_bootstrap).to receive(:send_heartbeat)

    handler.evacuate!(goodbye_message)
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

    it "stops the heartbeat timer" do
      expect(EM).to receive(:cancel_timer).with(terrible_bootstrap.heartbeat_timer)
      handler.evacuate!(goodbye_message)
    end

    context "with a mixture of instances in various states" do
      before { instances.each { |_, instance| instance_registry.register instance } }

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

    context 'when there are staging tasks present' do
      let(:task) { double('Task', :task_id => 'task-id') }

      before do
        staging_task_registry.register(task)
      end

      it 'returns can_shutdown as false' do
        expect(handler.evacuate!(goodbye_message)).to be false
      end

      context 'when the staging task unregisters and empties the registry' do
        before do
          expect(handler.evacuate!(goodbye_message)).to be false
          staging_task_registry.unregister(task)
        end

        it 'finishes evacuation' do
          expect(handler.evacuate!(goodbye_message)).to be true 
        end
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

      it "does not cancel the heartbeat_timer again" do
        expect(EM).to_not receive(:cancel_timer)
        handler.evacuate!(goodbye_message)
      end

      context "and the registry still has evacuating instances" do
        before do
          instance_registry.register(instances[:evacuating])
        end

        it "returns false (the dea should not be stopped yet)" do
          Timecop.travel now + 10*60 do
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
            Timecop.travel now + 15*60 do
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
          Timecop.travel now + 10*60 do
            expect(handler.evacuate!(goodbye_message)).to eq false
          end
        end
      end
    end
  end
end
