require "spec_helper"
require "dea/nats"
require "dea/staging_task_registry"
require "dea/directory_server_v2"
require "dea/responders/stage"

describe Dea::Responders::Stage do
  stub_nats

  let(:nats) { Dea::Nats.new(bootstrap, config) }
  let(:bootstrap) { mock(:bootstrap, :config => config) }
  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }
  let(:dir_server) { Dea::DirectoryServerV2.new("domain", 1234, config) }
  let(:config) { {"directory_server" => {"file_api_port" => 2345}} }

  subject { described_class.new(nats, bootstrap, staging_task_registry, dir_server, config) }

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
    context "when staging request is async" do
      let(:message) { Dea::Nats::Message.new(nats, nil, {}, "respond-to") }

      it "stages sync" do
        subject.should_receive(:stage_sync)
        subject.handle(message)
      end
    end

    context "when staging request is async" do
      let(:message) { Dea::Nats::Message.new(nats, nil, {"async" => true}, "respond-to") }

      it "stages async" do
        subject.should_receive(:stage_async)
        subject.handle(message)
      end
    end
  end

  describe "managing staging task" do
    let(:message) { Dea::Nats::Message.new(nats, nil, {"something" => "value"}, "respond-to") }
    let(:staging_task) { mock(:staging_task, :task_id => "task-id", :task_log => "task-log") }

    before { Dea::StagingTask.stub(:new => staging_task) }

    def self.it_registers_task(method)
      it "adds staging task to registry" do
        staging_task.stub(:start)

        expect {
          subject.send(method, message)
        }.to change {
          staging_task_registry.registered_task("task-id")
        }.from(nil).to(staging_task)
      end
    end

    def self.it_unregisters_task(method)
      it "unregisters task from registry" do
        expect {
          subject.send(method, message)
        }.to_not change {
          staging_task_registry.registered_task("task-id")
        }
      end
    end

    describe "#stage_sync" do
      it "starts staging task" do
        Dea::StagingTask
          .should_receive(:new)
          .with(bootstrap, dir_server, message.data)
          .and_return(staging_task)
        staging_task.should_receive(:start)
        subject.stage_sync(message)
      end

      it_registers_task :stage_sync

      context "when staging is successful" do
        before { staging_task.stub(:start).and_yield(nil) }

        it "responds with successful message" do
          nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
            "task_id" => "task-id",
            "task_log" => "task-log",
            "task_streaming_log_url" => nil,
            "error" => nil,
          ))
          subject.stage_sync(message)
        end

        it_unregisters_task :stage_sync
      end

      context "when staging task fails" do
        before { staging_task.stub(:start).and_yield(RuntimeError.new("error-description")) }

        it "responds with error message" do
          nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
            "task_id" => "task-id",
            "task_log" => "task-log",
            "task_streaming_log_url" => nil,
            "error" => "error-description",
          ))
          subject.stage_sync(message)
        end

        it_unregisters_task :stage_sync
      end
    end

    describe "#stage_asyncrhonously" do
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
        subject.stage_async(message)
      end

      it_registers_task :stage_async

      describe "after staging container setup" do
        before { staging_task.stub(:streaming_log_url).and_return("streaming-log-url") }

        context "when staging succeeds setting up staging container" do
          before { staging_task.stub(:after_setup).and_yield(nil) }

          it "responds with successful message" do
            nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
              "task_id" => "task-id",
              "task_log" => nil,
              "task_streaming_log_url" => "streaming-log-url",
              "error" => nil
            ))
            subject.stage_async(message)
          end
        end

        context "when staging fails to set up staging container" do
          before { staging_task.stub(:after_setup).and_yield(RuntimeError.new("error-description")) }

          it "responds with error message" do
            nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
              "task_id" => "task-id",
              "task_log" => nil,
              "task_streaming_log_url" => "streaming-log-url",
              "error" => "error-description",
            ))
            subject.stage_async(message)
          end
        end
      end

      describe "after staging completion" do
        before { staging_task.stub(:task_log).and_return("task-log") }

        context "when successfully" do
          before { staging_task.stub(:start).and_yield(nil) }

          it "responds successful message" do
            nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
              "task_id" => "task-id",
              "task_log" => "task-log",
              "task_streaming_log_url" => nil,
              "error" => nil
            ))
            subject.stage_async(message)
          end

          it_unregisters_task :stage_async
        end

        context "when failed" do
          before { staging_task.stub(:start).and_yield(RuntimeError.new("error-description")) }

          it "responds with error message" do
            nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
              "task_id" => "task-id",
              "task_log" => "task-log",
              "task_streaming_log_url" => nil,
              "error" => "error-description",
            ))
            subject.stage_async(message)
          end

          it_unregisters_task :stage_async
        end
      end
    end
  end
end
