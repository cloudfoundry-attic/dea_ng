require "spec_helper"
require "dea/bootstrap"

describe SignalHandler do
  around do |example|
    with_event_machine { example.call }
  end

  include_context "tmpdir"

  let(:message_bus) do
    bus = double(:message_bus, stop: nil, flush: nil)
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

  let(:instance_registry) { Dea::InstanceRegistry.new({}) }
  let(:staging_registry) { Dea::StagingTaskRegistry.new }
  let(:droplet_registry) { Dea::DropletRegistry.new(tmpdir) }
  let(:directory_server) { double(:dir_server, unregister: nil) }
  let(:logger) { double(:logger, info: nil, warn: nil, debug: nil, error: nil) }
  let(:local_ip) { "127.0.0.1" }
  let(:uuid) { "you-you-eye-dee" }

  let(:terrible_bootstrap) { double(:bootstrap, config: {}) }
  let(:instance) { Dea::Instance.new(terrible_bootstrap, valid_instance_attributes) }
  let(:config) do
    { "evacuation_bail_out_time_in_seconds" => 15 * 60 }
  end

  let(:evac_handler) { EvacuationHandler.new(terrible_bootstrap, message_bus, locator_responders, instance_registry, staging_registry, logger, config) }
  let(:shutdown_handler) { ShutdownHandler.new(message_bus, locator_responders, instance_registry, staging_registry, droplet_registry, directory_server, logger) }

  subject(:handler) do
    SignalHandler.new(uuid, local_ip, message_bus, locator_responders, instance_registry, evac_handler, shutdown_handler, logger)
  end

  before do
    @signal_handlers = {}
    handler.setup do |signal, &block|
      @signal_handlers[signal] = block
    end
  end

  describe "signal handler behavior" do
    before do
      allow(Thread).to receive(:new) do |&block|
        block.call
      end
    end

    describe "#trap_term" do
      it "shutsdown the system" do
        expect(shutdown_handler).to receive(:shutdown!)

        @signal_handlers["TERM"].call
        done
      end
    end

    describe "#trap_int" do
      it "shutsdown the system" do
        expect(shutdown_handler).to receive(:shutdown!)

        @signal_handlers["INT"].call
        done
      end
    end

    describe "#trap_quit" do
      it "shutsdown the system" do
        expect(shutdown_handler).to receive(:shutdown!)

        @signal_handlers["QUIT"].call
        done
      end
    end

    describe "#trap_usr1" do
      it "sends the shutdown message" do
        @signal_handlers["USR1"].call
        shutdown_message = @published_messages["dea.shutdown"][0]
        expect(shutdown_message["id"]).to eq uuid
        expect(shutdown_message["ip"]).to eq local_ip
        expect(shutdown_message["app_id_to_count"]).to be
        done
      end

      it "stops advertising" do
        locator_responders.each do |locator|
          expect(locator).to receive(:stop)
        end

        @signal_handlers["USR1"].call
        done
      end
    end

    describe "#trap_usr2" do
      context 'when evacuation is not complete' do
        it "does not shutdown the system" do
          expect(evac_handler).to receive(:evacuate!).and_return(false)
          expect(shutdown_handler).not_to receive(:shutdown!)
          timer_block = nil
          expect(EM).to receive(:add_timer).with(5) do |&callback|
            timer_block = callback
          end

          @signal_handlers["USR2"].call

          expect(timer_block).not_to be_nil
          expect(handler).to receive(:evacuate)
          timer_block.call
          done
        end
      end

      context 'when evacuation is complete' do
        it "does shutdown the system" do
          expect(evac_handler).to receive(:evacuate!).and_return(true)
          expect(shutdown_handler).to receive(:shutdown!)
          @signal_handlers["USR2"].call
          done
        end
      end
    end
  end

  describe "scheduling signal handler execution" do
    it "spawns a thread to schedule the handler to event machine" do
      allow(handler).to receive(:trap_quit) do
        done
      end

      allow(Thread).to receive(:new).and_yield
      allow(EM).to receive(:schedule).and_call_original
      @signal_handlers["QUIT"].call
    end
  end
end
