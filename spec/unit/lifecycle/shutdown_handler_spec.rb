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
  let(:instance) { Dea::Instance.new(terrible_bootstrap, valid_instance_attributes) }

  let(:staging_registry) { Dea::StagingTaskRegistry.new }
  let(:stager) { Dea::StagingTask.new(terrible_bootstrap, nil, StagingMessage.new(valid_staging_attributes), [], logger) }

  let(:sha) { "sha1" }
  let(:droplet_registry) { Dea::DropletRegistry.new(tmpdir) }
  let(:droplet) { Dea::Droplet.new(tmpdir, sha)}

  let(:goodbye_message) { "sayonara dea" }
  let(:directory_server) { double(:directory_server, unregister: nil) }

  subject(:handler) { ShutdownHandler.new(
      message_bus,
      locator_responders,
      instance_registry,
      staging_registry,
      droplet_registry,
      directory_server,
      logger
    )
  }

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

    it "flushes the message bus and terminates" do
      expect(handler).to receive(:flush_message_bus_and_terminate)
      handler.shutdown!(goodbye_message)
    end

    context "when the message bus finishes flushing" do
      it "terminates the process" do
        handler.shutdown!(goodbye_message)

        expect(handler).to receive(:terminate)
        expect(@flush_callback).not_to be_nil
        @flush_callback.call
      end
    end

    context "with instances and/or stagers" do
      before do
        instance_registry.register(instance)
        staging_registry.register(stager)
      end

      it "stops them" do
        expect(instance).to receive(:stop)
        expect(stager).to receive(:stop)

        handler.shutdown!(goodbye_message)
      end

      it "flushes the message bus and terminates" do
        expect(handler).to receive(:flush_message_bus_and_terminate)
        handler.shutdown!(goodbye_message)
      end

      context "when the stopping fails" do
        before do
          allow(instance).to receive(:stop).and_yield('error')
          allow(stager).to receive(:stop).and_yield('error')
        end

        it "logs" do
          expect(instance.logger).to receive(:warn).with(/failed to stop/i)
          expect(stager.logger).to receive(:warn).with(/failed to stop/i)
          handler.shutdown!(goodbye_message)
        end

        it "flushes the message bus and terminates" do
          expect(handler).to receive(:flush_message_bus_and_terminate)
          handler.shutdown!(goodbye_message)
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
