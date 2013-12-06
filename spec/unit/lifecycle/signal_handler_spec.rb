require "spec_helper"
require "dea/bootstrap"

describe SignalHandler do
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

  subject(:handler) do
    SignalHandler.new(uuid, local_ip, message_bus, locator_responders, instance_registry, staging_registry, droplet_registry, directory_server, logger, config)
  end

  before do
    @signal_handlers = {}

    handler.setup do |signal, &block|
      @signal_handlers[signal] = block
    end
  end

  describe "#trap_term" do
    it "shutsdown the system" do
      expect(message_bus).to receive(:stop)

      @signal_handlers["TERM"].call
      expect(@published_messages["dea.shutdown"]).to have(1).item
    end
  end

  describe "#trap_int" do
    it "shutsdown the system" do
      expect(message_bus).to receive(:stop)

      @signal_handlers["INT"].call
      expect(@published_messages["dea.shutdown"]).to have(1).item
    end
  end

  describe "#trap_quit" do
    it "shutsdown the system" do
      expect(message_bus).to receive(:stop)

      @signal_handlers["QUIT"].call
      expect(@published_messages["dea.shutdown"]).to have(1).item
    end
  end

  describe "#trap_usr1" do
    it "sends the shutdown message" do
      @signal_handlers["USR1"].call
      shutdown_message = @published_messages["dea.shutdown"][0]
      expect(shutdown_message["id"]).to eq uuid
      expect(shutdown_message["ip"]).to eq local_ip
      expect(shutdown_message["app_id_to_count"]).to be
    end

    it "stops advertising" do
      locator_responders.each do |locator|
        expect(locator).to receive(:stop)
      end

      @signal_handlers["USR1"].call
    end
  end

  describe "#trap_usr2" do
    before do
      instance_registry.register(instance)
      @signal_handlers["USR2"].call
    end

    it "evacuates the system, and does not shut it down" do
      expect(@published_messages["droplet.exited"]).to have(1).item
      expect(@published_messages["dea.shutdown"]).to have(1).item
    end

    context "when the evacuation is finished" do
      before do
        instance.state = Dea::Instance::State::STOPPED
      end

      it "shutsdown the system" do
        expect(message_bus).to receive(:stop)
        @signal_handlers["USR2"].call
        expect(@published_messages["dea.shutdown"]).to have(2).items
      end
    end
  end
end