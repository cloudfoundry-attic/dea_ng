# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe "Dea::Bootstrap#handle_dea_stop" do
  include_context "bootstrap_setup"

  def publish(message = {})
    with_event_machine do
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
    allow(manager).to receive(:could_reserve?).and_return(true)
    allow(manager).to receive(:number_reservable).and_return(123)
    manager
  end

  let(:instance_registry) { double(:instance_registry, :register => nil, :unregister => nil, :each => []) }

  before do
    allow(bootstrap).to receive(:setup_router_client).and_call_original
    with_event_machine do
      bootstrap.setup
      done
    end

    allow_any_instance_of(Dea::Instance).to receive(:setup_link)
    allow_any_instance_of(Dea::Responders::DeaLocator).to receive(:start) # to deal with test pollution
    allow(bootstrap).to receive(:resource_manager).and_return(resource_manager)
    allow(bootstrap).to receive(:instance_registry).and_return(instance_registry)
    allow(bootstrap).to receive(:send_heartbeat)

    allow(instance_registry).to receive(:instances_filtered_by_message).and_yield(instance_mock)
    allow(instance_mock).to receive(:promise_stop).and_return(delivering_promise)
    allow(instance_mock).to receive(:destroy)
  end

  describe 'stopping instances' do
    describe "filtering" do
      before do
        allow(instance_registry).to receive(:instances_filtered_by_message) do
          EM.next_tick do
            done
          end
        end.and_yield(instance_mock)
      end

      it "skips instances that are not running" do
        instance_mock.state = Dea::Instance::State::STOPPED
        expect(instance_mock).to_not receive(:stop)

        publish
      end

      def self.it_stops_the_instance
        it "stops the instance" do
          expect(instance_mock).to receive(:stop)

          publish
        end
      end

      context "when the app is born" do
        before { instance_mock.state = Dea::Instance::State::BORN }

        it_stops_the_instance
      end

      context "when the app is starting" do
        before { instance_mock.state = Dea::Instance::State::STARTING }

        it_stops_the_instance
      end

      context "when the app is running" do
        before { instance_mock.state = Dea::Instance::State::RUNNING }

        it_stops_the_instance
      end

      context "when the app is evacuating" do
        before { instance_mock.state = Dea::Instance::State::EVACUATING }

        it_stops_the_instance
      end

      context "when the app is stopping" do
        before { instance_mock.state = Dea::Instance::State::STOPPING }

        it_stops_the_instance
      end

      [Dea::Instance::State::STOPPED, Dea::Instance::State::CRASHED,
       Dea::Instance::State::RESUMING].each do |state|
        context "when the app is #{state}" do
          before { instance_mock.state = state }

          it 'does not stop' do
            expect(instance_mock).not_to receive(:stop)

            publish
          end
        end
      end
    end

    describe "when stop completes" do
      let(:logger) { double("logger") }

      before do
        allow(bootstrap).to receive(:logger).and_return(logger)
        allow(instance_mock).to receive(:running?).and_return(true)

        allow(instance_registry).to receive(:instances_filtered_by_message) do
          EM.next_tick do
            done
          end
        end.and_yield(instance_mock)
      end

      describe "with failure" do
        before do
          allow(instance_mock).to receive(:stop).and_yield(RuntimeError.new("Error"))
        end

        it "works" do
          expect(logger).to receive(:info).with("Dea started", hash_including(:uuid))
          expect(logger).to receive(:warn)
          publish
        end
      end

      describe "with success" do
        before do
          allow(instance_mock).to receive(:stop).and_yield(nil)
        end

        it "works" do
          expect(logger).to receive(:info).with("Dea started", hash_including(:uuid))
          expect(logger).not_to receive(:warn)
          publish
        end
      end
    end
  end

  describe 'stop staging' do
    let(:nats_staging_responder) { Dea::Responders::NatsStaging.new(nats_mock, bootstrap.uuid, bootstrap.staging_responder, bootstrap.config) }

    before do
      allow(Dea::Responders::NatsStaging).to receive(:new).and_return(nats_staging_responder)
    end

    context 'when message is an app stop' do
      it 'sends a stop message to the staging responder' do
        expect(nats_staging_responder).to receive(:handle_stop) do |msg|
          expect(msg.subject).to eq 'staging.stop'
          expect(msg.data).to eq({'app_id'  => 'app-id'})
        end
        publish({'droplet' => 'app-id'})
      end
    end

    context 'when message is an instance/index stop' do
      it 'does not send a stop message to the staging responder' do
        expect(nats_staging_responder).to_not receive(:handle_stop)
        publish({data:{'droplet' => 'app-id', 'version' => '3'}})
      end
    end

    context 'when the message has no droplet' do
      it 'does not send a stop message to the staging responder' do
        expect(nats_staging_responder).to_not receive(:handle_stop)
        publish({data:{'version' => '3'}})
      end
    end
  end
end
