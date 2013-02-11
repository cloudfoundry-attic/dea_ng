require "spec_helper"
require "dea/nats"
require "dea/responders/async_stage"
require "dea/directory_server_v2"

describe Dea::Responders::AsyncStage do
  stub_nats

  let(:nats) { Dea::Nats.new(bootstrap, config) }
  let(:config) { {"directory_server" => {"file_api_port" => 2345}} }
  let(:bootstrap) { mock(:bootstrap, :config => config) }
  let(:dir_server) { Dea::DirectoryServerV2.new("domain", 1234, nil, config) }

  subject { described_class.new(nats, bootstrap, dir_server, config) }

  describe "#start" do
    context "when config does not allow staging operations" do
      before { config.delete("staging") }

      it "does not listen to staging" do
        subject.start
        subject.should_not_receive(:handle)
        nats_mock.publish("staging.async")
      end
    end

    context "when the config allows staging operation" do
      before { config["staging"] = {"enabled" => true} }

      it "subscribes to staging message" do
        subject.start
        subject.should_receive(:handle)
        nats_mock.publish("staging.async")
      end

      it "subscribes to staging message as part of the queue group" do
        nats.should_receive(:subscribe).with("staging.async", hash_including(:queue => "staging.async"))
        subject.start
      end

      it "subscribes to staging message but manually tracks the subscription" do
        nats.should_receive(:subscribe).with("staging.async", hash_including(:do_not_track_subscription => true))
        subject.start
      end
    end
  end

  describe "#stop" do
    before { config["staging"] = {"enabled" => true} }

    context "when subscription was made" do
      before { subject.start }

      it "unsubscribes to staging message" do
        subject.should_receive(:handle) # sanity check
        nats_mock.publish("staging.async")

        subject.stop
        subject.should_not_receive(:handle)
        nats_mock.publish("staging.async")
      end
    end

    context "when subscription was not made" do
      it "does not unsubscribe" do
        nats.should_not_receive(:unsubscribe)
        subject.stop
      end
    end
  end

  describe "#handle" do
    let(:message) { Dea::Nats::Message.new(nats, nil, {"something" => "value"}, "respond-to") }
    let(:staging_task) { mock(:staging_task, :task_id => "task-id") }

    before { Dea::StagingTask.stub(:new => staging_task) }

    before do
      staging_task.stub(:after_setup)
      staging_task.stub(:start)
    end

    it "starts staging task" do
      Dea::StagingTask
        .should_receive(:new)
        .with(bootstrap, dir_server, message.data)
        .and_return(staging_task)
      staging_task.should_receive(:start)
      subject.handle(message)
    end

    context "when staging succeeds setting up staging container" do
      before do
        staging_task.stub(:streaming_log_url).and_return("streaming-log-url")
        staging_task.stub(:after_setup).and_yield(nil)
      end

      it "responds with successful message" do
        nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
          "task_id" => "task-id",
          "streaming_log_url" => "streaming-log-url",
          "error" => nil
        ))
        subject.handle(message)
      end
    end

    context "when staging fails to set up staging container" do
      before do
        staging_task.stub(:streaming_log_url).and_return(nil)
        staging_task.stub(:after_setup).and_yield(RuntimeError.new("error-description"))
      end

      it "responds with error message" do
        nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
          "task_id" => "task-id",
          "streaming_log_url" => nil,
          "error" => "error-description",
        ))
        subject.handle(message)
      end
    end
  end
end
