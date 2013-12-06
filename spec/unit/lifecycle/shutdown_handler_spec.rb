require "spec_helper"
require "dea/bootstrap"

describe ShutdownHandler do
  include_context "tmpdir"

  let(:terrible_bootstrap) { double(:bootstrap, config: {}) }

  let(:message_bus) do
    bus = double(:message_bus, stop: nil)

    @published_messages = {}
    allow(bus).to receive(:publish) do |subject, message|
      @published_messages[subject] ||= []
      @published_messages[subject] << message
    end

    @flush_callback = nil
    allow(bus).to receive(:flush) do |&callback|
      @flush_callback = callback
    end

    bus
  end

  let(:locator_responders) do
    [
      double(:stager_advertiser, stop: nil),
      double(:dea_advertiser, stop: nil)
    ]
  end

  let(:logger) { double(:logger, error: nil, info: nil, warn: nil, debug: nil, user_data: {}) }

  let(:instance_registry) { Dea::InstanceRegistry.new({}) }
  let(:instance) do
    @instance_stop_callback = nil
    instance = Dea::Instance.new(terrible_bootstrap, valid_instance_attributes)
    allow(instance).to receive(:stop) do |&callback|
      @instance_stop_callback = callback
    end
    instance
  end

  let(:staging_registry) { Dea::StagingTaskRegistry.new }
  let(:stager) do
    @stager_stop_callback = nil
    stager = Dea::StagingTask.new(terrible_bootstrap, nil, StagingMessage.new(valid_staging_attributes), [], logger)
    allow(stager).to receive(:stop) do |&callback|
      @stager_stop_callback = callback
    end
    stager
  end

  let(:sha) { "sha1" }
  let(:droplet_registry) { Dea::DropletRegistry.new(tmpdir) }
  let(:droplet) { Dea::Droplet.new(tmpdir, sha)}

  let(:goodbye_message) { "sayonara dea" }
  let(:directory_server) { double(:directory_server, unregister: nil) }

  subject(:handler) do
    @terminate_count = 0
    handler = ShutdownHandler.new(
      message_bus,
      locator_responders,
      instance_registry,
      staging_registry,
      droplet_registry,
      directory_server,
      logger
    )
    allow(handler).to receive(:terminate) do
      @terminate_count += 1
    end
    handler
  end

  before do
    allow(EM).to receive(:defer) do |operation, &_|
      operation.call
    end
  end

  describe "#shutdown!" do
    it "sends a shutdown message" do
      handler.shutdown!(goodbye_message)
      expect(@published_messages["dea.shutdown"]).to include goodbye_message
    end

    it "stops advertising (we do this because we don't want to respond to anything in the background while we spend time shutting down)" do
      locator_responders.each do |locator|
        expect(locator).to receive(:stop)
      end

      handler.shutdown!(goodbye_message)
    end

    it "unsubscribes the message bus from everything (same reason as stoping the adverisments)" do
      expect(message_bus).to receive(:stop)
      handler.shutdown!(goodbye_message)
    end

    it "unregisters the directory server" do
      expect(directory_server).to receive(:unregister)
      handler.shutdown!(goodbye_message)
    end

    it "reaps all droplets irrespective of their being an active instance or staging task using that droplet" do
      droplet_registry[sha] = droplet
      expect {
        handler.shutdown!(goodbye_message)
      }.to change {
        File.exists?(droplet.droplet_dirname)
      }.from(true).to(false)
    end

    context "with instances and/or stagers" do
      before do
        instance_registry.register(instance)
        staging_registry.register(stager)

        expect(instance).to receive(:stop)
        expect(stager).to receive(:stop)

        handler.shutdown!(goodbye_message)
      end

      it "stops them" do
        expect(@stager_stop_callback).not_to be_nil
        expect(@instance_stop_callback).not_to be_nil
      end

      context "when all instances/stagers have stopped succesfully" do
        before do
          @stager_stop_callback.call

          expect(@flush_callback).to be_nil
          expect(@terminate_count).to eq 0

          @instance_stop_callback.call
        end

        it "flushes the message bus" do
          expect(@flush_callback).to be
        end

        context "when the message bus finishes flushing" do
          it "terminates the process" do
            @flush_callback.call
            expect(@terminate_count).to eq 1
          end
        end
      end

      context "when the stopping fails" do
        before do
          @instance_stop_callback.call
        end

        it "logs" do
          expect(logger).to receive(:warn).with(/failed to stop/i)
          @stager_stop_callback.call("Failed to stop.")
        end

        it "still shuts down once all tasks have stopped or failed to stop" do
          @stager_stop_callback.call("Failed to stop.")
          @flush_callback.call
          expect(@terminate_count).to eq 1
        end
      end
    end

    context "with no instances or stagers" do
      before do
        handler.shutdown!(goodbye_message)
      end

      it "flushes the message bus" do
        expect(@flush_callback).to be
      end

      context "when the message bus finishes flushing" do
        it "terminates the process" do
          @flush_callback.call
          expect(@terminate_count).to eq 1
        end
      end
    end

    context "when already called" do
      it "does nothing (presume the previous kill will eventually work)" do
        expect(message_bus).to receive(:stop).once

        handler.shutdown!(goodbye_message)

        @published_messages = {}

        handler.shutdown!(goodbye_message)

        expect(@published_messages["dea.shutdown"]).to be_nil
      end
    end
  end
end