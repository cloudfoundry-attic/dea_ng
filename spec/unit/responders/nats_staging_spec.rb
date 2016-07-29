require "spec_helper"
require "dea/nats"
require "dea/directory_server/directory_server_v2"

require "dea/staging/staging_task_registry"

require "dea/responders/nats_staging"
require "dea/responders/staging"

describe Dea::Responders::NatsStaging do
  stub_nats

  let(:nats) { Dea::Nats.new(bootstrap, config) }
  let(:dea_id) { "unique-dea-id" }
  let(:snapshot) { double(:snapshot, :save => nil, :load => nil)}
  let(:bootstrap) { double(:bootstrap, :config => config, :snapshot => snapshot) }
  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }
  let(:buildpack_key) { nil }
  let(:staging_error_info) { nil }
  let(:staging_task) do
    double(:staging_task,
      task_id: "task-id",
      streaming_log_url: "log url",
    )
  end
  let(:app_id) { "my_app_id" }
  let(:message) { Dea::Nats::Message.new(nats, nil, {"app_id" => app_id}, "respond-to") }
  let(:staging_message) { double(StagingMessage) }
  let(:resource_manager) { double(:resource_manager, :could_reserve? => true) }
  let(:config) { {"directory_server" => {"file_api_port" => 2345}} }

  let(:stager) { double(Dea::Responders::Staging, :create_task => staging_task) }

  before do
    allow(config).to receive(:minimum_staging_memory_mb).and_return(1)
    allow(config).to receive(:minimum_staging_disk_mb).and_return(2)
  end


  subject { described_class.new(nats, dea_id, stager, config) }

  describe "#start" do
    context "when config does not allow staging operations" do
      before { config.delete("staging") }

      it "does not listen to staging.<dea-id>.start" do
        subject.start
        expect(subject).to_not receive(:handle)
        nats_mock.publish("staging.#{dea_id}.start")
      end
    end

    context "when the config allows staging operation" do
      before { config["staging"] = {"enabled" => true} }

      it "subscribes to 'staging.<dea-id>.start' message" do
        subject.start
        expect(subject).to receive(:handle)
        nats_mock.publish("staging.#{dea_id}.start")
      end

      it "subscribes to 'staging.stop' message" do
        subject.start
        expect(subject).to receive(:handle_stop)
        nats_mock.publish("staging.stop")
      end

      it "subscribes to staging message as part of the queue group" do
        expect(nats_mock).to receive(:subscribe).with("staging.#{dea_id}.start", {})
        expect(nats_mock).to receive(:subscribe).with("staging.stop", {})
        subject.start
      end

      it "subscribes to staging message but manually tracks the subscription" do
        allow(nats).to receive(:subscribe).with(
          "staging.#{dea_id}.start", hash_including(:do_not_track_subscription => true))
        allow(nats).to receive(:subscribe).with(
          "staging.stop", hash_including(:do_not_track_subscription => true))
        subject.start
      end
    end
  end

  describe "#stop" do
    before { config["staging"] = {"enabled" => true} }

    context "when subscription was made" do
      before { subject.start }

      it "unsubscribes from 'staging.stop' message" do
        allow(subject).to receive(:handle_stop) # sanity check
        nats_mock.publish("staging.stop")

        subject.stop
        expect(subject).to_not receive(:handle_stop)
        nats_mock.publish("staging.stop")
      end

      it "unsubscribes from 'staging.<dea-id>.start' message" do
        allow(subject).to receive(:handle) # sanity check
        nats_mock.publish("staging.#{dea_id}.start")

        subject.stop
        expect(subject).to_not receive(:handle)
        nats_mock.publish("staging.#{dea_id}.start")
      end
    end

    context "when subscription was not made" do
      it "does not unsubscribe" do
        expect(nats).to_not receive(:unsubscribe)
        subject.stop
      end
    end
  end

  describe '#handle' do
    before do
      allow(StagingMessage).to receive(:new).with(message.data).and_return(staging_message)
      allow(staging_message).to receive(:set_responder)
      allow(staging_task).to receive(:after_setup_callback)
      allow(staging_task).to receive(:start)
    end

    it 'sets the responder to the Nats Message to accept a block' do
      called = false

      expect(staging_message).to receive(:set_responder) do |&blk|
        expect(message).to receive(:respond) do | params, &completion_blk|
          completion_blk.call
        end
        blk.call { called = true }
      end

      subject.handle(message) 
      expect(called).to be true
    end

    it 'sets up a after_setup_callback' do
        expect(staging_task).to receive(:after_setup_callback)
        subject.handle(message)
    end

    it 'starts the staging task' do
        expect(staging_task).to receive(:start)
        subject.handle(message)
    end

    describe 'notify_setup_completion' do
      let(:data) { { :task_id => staging_task.task_id, :task_streaming_log_url => staging_task.streaming_log_url, :error => nil} }

      it 'responds to the request with response data' do
        expect(staging_task).to receive(:after_setup_callback) do |&blk|
          expect(message).to receive(:respond).with(data)
          blk.call
        end
        subject.handle(message) 
      end
    end

    context 'when creating a task fails' do
      before do
        allow(stager).to receive(:create_task).and_return(nil)
      end

      it 'does assign an after_setup_callback' do
        expect(staging_task).to_not receive(:after_setup_callback)
        subject.handle(message)
      end

      it 'does not start' do
        expect(staging_task).to_not receive(:start)
        subject.handle(message)
      end
    end
  end

  describe "#handle_stop" do
    it 'calls the stager stop_tas' do
      expect(stager).to receive(:stop_task).with(app_id)
      subject.handle_stop(message)
    end
  end
end
