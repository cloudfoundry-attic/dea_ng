require "spec_helper"
require "dea/nats"
require "dea/directory_server_v2"
require "dea/responders/stage"

describe Dea::Responders::Stage do
  stub_nats

  let(:nats) { Dea::Nats.new(bootstrap, config) }
  let(:bootstrap) { mock(:bootstrap, :config => config) }
  subject { described_class.new(nats, bootstrap, config) }
  let(:dir_server) { Dea::DirectoryServerV2.new("domain", 1234, nil, config) }
  let(:config) { {"directory_server" => {"file_api_port" => 2345}} }


  describe "#start" do
    context "when config does not allow staging operations" do
      before { config.delete("staging") }

      it "does not listen to staging" do
        subject.start
        subject.should_not_receive(:handle)
        nats_mock.publish("staging")
      end
    end

    context "when the config allows staging operation" do
      before { config["staging"] = {"enabled" => true} }

      it "subscribes to staging message" do
        subject.start
        subject.should_receive(:handle)
        nats_mock.publish("staging")
      end

      it "subscribes to staging message as part of the queue group" do
        nats_mock.should_receive(:subscribe).with("staging", :queue => "staging")
        subject.start
      end

      it "subscribes to staging message but manually tracks the subscription" do
        nats.should_receive(:subscribe).with("staging", hash_including(:do_not_track_subscription => true))
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
        nats_mock.publish("staging")

        subject.stop
        subject.should_not_receive(:handle)
        nats_mock.publish("staging")
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
    let(:staging_task) { mock(:staging_task, :task_id => "task-id", :task_log => "task-log") }

    before { Dea::StagingTask.stub(:new => staging_task) }

    it "starts staging task" do
      Dea::StagingTask
        .should_receive(:new)
        .with(bootstrap, anything, message.data)
        .and_return(staging_task)
      staging_task.should_receive(:start)
      subject.handle(message)
    end

    context "when staging is successful" do
      before { staging_task.stub(:start).and_yield(nil) }

      it "responds with successful message" do
        nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
          "task_id" => "task-id",
          "task_log" => "task-log",
        ))
        subject.handle(message)
      end
    end

    context "when staging task fails" do
      before { staging_task.stub(:start).and_yield(RuntimeError.new("error-description")) }

      it "responds with error message" do
        nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
          "task_id" => "task-id",
          "task_log" => "task-log",
          "error" => "error-description",
        ))
        subject.handle(message)
      end
    end
  end
end
