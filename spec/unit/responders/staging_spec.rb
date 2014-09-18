require "spec_helper"
require "dea/nats"
require "dea/directory_server/directory_server_v2"

require "dea/staging/staging_task_registry"

require "dea/responders/staging"

describe Dea::Responders::Staging do
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
      staging_message: staging_message,
      task_id: "task-id",
      task_log: "task-log",
      detected_buildpack: nil,
      buildpack_key: buildpack_key,
      detected_start_command: "bacofoil",
      droplet_sha1: "some-droplet-sha",
      memory_limit_mb: 1,
      disk_limit_mb: 2,
      error_info: staging_error_info
    )
  end
  let(:dir_server) { Dea::DirectoryServerV2.new("domain", 1234, config) }
  let(:app_id) { "my_app_id" }
  let(:message) { Dea::Nats::Message.new(nats, nil, {"app_id" => app_id}, "respond-to") }
  let(:staging_message) { StagingMessage.new(message.data) }
  let(:resource_manager) { double(:resource_manager, :could_reserve? => true) }
  let(:config) { {"directory_server" => {"file_api_port" => 2345}} }

  before do
    config.stub(:minimum_staging_memory_mb) { 1 }
    config.stub(:minimum_staging_disk_mb) { 2 }
  end

  subject { described_class.new(nats, dea_id, bootstrap, staging_task_registry, dir_server, resource_manager, config) }

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

      it "subscribes to 'staging' message" do
        subject.start
        subject.should_receive(:handle)
        nats_mock.publish("staging")
      end

      it "subscribes to 'staging.<dea-id>.start' message" do
        subject.start
        subject.should_receive(:handle)
        nats_mock.publish("staging.#{dea_id}.start")
      end

      it "subscribes to 'staging.stop' message" do
        subject.start
        subject.should_receive(:handle_stop)
        nats_mock.publish("staging.stop")
      end

      it "subscribes to staging message as part of the queue group" do
        nats_mock.should_receive(:subscribe).with("staging", :queue => "staging")
        nats_mock.should_receive(:subscribe).with("staging.#{dea_id}.start", {})
        nats_mock.should_receive(:subscribe).with("staging.stop", {})
        subject.start
      end

      it "subscribes to staging message but manually tracks the subscription" do
        nats.should_receive(:subscribe).with(
          "staging", hash_including(:do_not_track_subscription => true))
        nats.should_receive(:subscribe).with(
          "staging.#{dea_id}.start", hash_including(:do_not_track_subscription => true))
        nats.should_receive(:subscribe).with(
          "staging.stop", hash_including(:do_not_track_subscription => true))
        subject.start
      end
    end
  end

  describe "#stop" do
    before { config["staging"] = {"enabled" => true} }

    context "when subscription was made" do
      before { subject.start }

      it "unsubscribes from 'staging' message" do
        subject.should_receive(:handle) # sanity check
        nats_mock.publish("staging")

        subject.stop
        subject.should_not_receive(:handle)
        nats_mock.publish("staging")
      end

      it "unsubscribes from 'staging.stop' message" do
        subject.should_receive(:handle_stop) # sanity check
        nats_mock.publish("staging.stop")

        subject.stop
        subject.should_not_receive(:handle_stop)
        nats_mock.publish("staging.stop")
      end

      it "unsubscribes from 'staging.<dea-id>.start' message" do
        subject.should_receive(:handle) # sanity check
        nats_mock.publish("staging.#{dea_id}.start")

        subject.stop
        subject.should_not_receive(:handle)
        nats_mock.publish("staging.#{dea_id}.start")
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
    before do
      Dea::StagingTask.stub(:new => staging_task)
      staging_task.stub(:after_setup_callback)
      staging_task.stub(:after_complete_callback)
      staging_task.stub(:after_stop_callback)
      staging_task.stub(:start)
    end

    def self.it_registers_task
      it "adds staging task to registry" do
        expect {
          subject.handle(message)
        }.to change {
          staging_task_registry.registered_task("task-id")
        }.from(nil).to(staging_task)
      end
    end

    def self.it_unregisters_task
      it "unregisters task from registry" do
        expect {
          subject.handle(message)
        }.to_not change {
          staging_task_registry.registered_task("task-id")
        }
      end
    end

    context "staging async" do
      it "starts staging task with registered callbacks" do
        Dea::StagingTask
          .should_receive(:new)
          .with(bootstrap, dir_server, instance_of(StagingMessage), [], an_instance_of(Steno::TaggedLogger))
          .and_return(staging_task)

        staging_task.should_receive(:after_setup_callback).ordered
        staging_task.should_receive(:after_complete_callback).ordered
        staging_task.should_receive(:start).ordered

        subject.handle(message)
      end

      it "passes a list of all potentially in-use buildpacks to the staging task" do

        staging_task_registry.register(task_double ["a", "b", "c"])
        staging_task_registry.register(task_double ["b", "c"])
        staging_task_registry.register(task_double ["b", "c", "d", "e"])

        buildpacks_in_use = ["a", "b", "c", "d", "e"].map do |key|
          { url: URI("http://www.goolge.com"), key: key }
        end

        Dea::StagingTask
          .should_receive(:new)
          .with(bootstrap, dir_server, instance_of(StagingMessage), buildpacks_in_use, an_instance_of(Steno::TaggedLogger))
          .and_return(staging_task)

        subject.handle(message)
      end

      def task_double(buildpack_keys)
        Struct.new(:task_id, :staging_message).new(SecureRandom.uuid, StagingMessage.new("admin_buildpacks" => as_buildpacks(buildpack_keys)))
      end

      def as_buildpacks(buildpack_keys)
        buildpack_keys.map do |key|
          { "url" => "http://www.goolge.com", "key" => key }
        end
      end

      it_registers_task

      it "saves snapshot" do
        bootstrap.snapshot.should_receive(:save)
        subject.handle(message)
      end

      describe "after staging container setup" do
        before { staging_task.stub(:streaming_log_url).and_return("streaming-log-url") }

        context "when staging succeeds setting up staging container" do
          before { staging_task.stub(:after_setup_callback).and_yield(nil) }

          it "responds with successful message" do
            nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
              "task_id" => "task-id",
              "task_streaming_log_url" => "streaming-log-url",
              "error" => nil,
            ))
            subject.handle(message)
          end
        end

        context "when staging fails to set up staging container" do
          before { staging_task.stub(:after_setup_callback).and_yield(RuntimeError.new("error-description")) }

          it "responds with error message" do
            nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
              "task_id" => "task-id",
              "task_streaming_log_url" => "streaming-log-url",
              "error" => "error-description",
            ))
            subject.handle(message)
          end
        end
      end

      describe "after staging completed" do
        context "when successfully" do
          let(:buildpack_key) { "some_buildpack_key" }

          before do
            staging_task.stub(:after_complete_callback).and_yield(nil)
            bootstrap.stub(:start_app)
          end

          it "responds successful message" do
            nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
              "task_id" => "task-id",
              "detected_buildpack" => nil,
              "buildpack_key" => "some_buildpack_key",
              "droplet_sha1" => "some-droplet-sha",
              "detected_start_command" => "bacofoil",
            ))
            subject.handle(message)
          end

          it_unregisters_task

          it "saves snapshot" do
            called = false

            staging_task.should_receive(:after_complete_callback) do |&blk|
              bootstrap.snapshot.should_receive(:save)
              blk.call
              called = true
            end

            subject.handle(message)

            expect(called).to be_true
          end

          it "logs to the loggregator" do
            emitter = FakeEmitter.new
            Dea::Loggregator.emitter = emitter

            subject.handle(message)
            expect(emitter.messages[app_id][0]).to eql("Got staging request for app with id #{app_id}")
          end

          context "when there is a start message in staging message" do
            let(:start_message) { {"droplet" => "dff77854-3767-41d9-ab16-c8a824beb77a", "sha1" => "some-droplet-sha"} }
            let(:message) { Dea::Nats::Message.new(nats, nil, {"app_id" => app_id, "start_message" => start_message}, "respond-to") }

            it "handles instance start with updated droplet sha" do
              bootstrap.should_receive(:start_app).with(start_message)
              subject.handle(message)
            end
          end
        end

        context "when failed" do
          let(:staging_error_info) {{ "type" => "NoAppDetectedError", "message" => "oh noes" }}
          before do
            staging_task.stub(:after_complete_callback) do |&blk|
              staging_task.stub(:droplet_sha1) { nil }
              blk.call(RuntimeError.new("error-description"))
            end
          end

          it "responds with error message" do
            nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
              "task_id" => "task-id",
              "detected_buildpack" => nil,
              "buildpack_key" => nil,
              "droplet_sha1" => nil,
              "detected_start_command" => "bacofoil",
              "error" => "error-description",
              "error_info" => staging_error_info,
            ))
            subject.handle(message)
          end

          it_unregisters_task

          it "saves snapshot" do
            called = false

            staging_task.should_receive(:after_complete_callback) do |&blk|
              bootstrap.snapshot.should_receive(:save)
              blk.call(RuntimeError.new("error-description"))
              called = true
            end

            subject.handle(message)

            expect(called).to be_true
          end

          it "does not start an instance" do
            bootstrap.should_not_receive(:start_app)
            subject.handle(message)
          end
        end

        context "when stopped" do
          before { staging_task.stub(:after_stop_callback).and_yield(Dea::StagingTask::StagingTaskStoppedError.new) }

          it "responds with error message" do
            nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
              "task_id" => "task-id",
              "error" => "Error staging: task stopped",
            ))
            subject.handle(message)
          end

          it_unregisters_task

          it "saves snapshot" do
            called = false

            staging_task.should_receive(:after_stop_callback) do |&blk|
              bootstrap.snapshot.should_receive(:save)
              blk.call
              called = true
            end

            subject.handle(message)

            expect(called).to be_true
          end
        end
      end
    end

    context "when an error occurs during staging" do
      it "catches the error since this is the top level" do
        Dea::StagingTask.stub(:new).and_raise(RuntimeError, "Some Horrible thing happened")
        expect { subject.handle(message) }.to_not raise_error
      end
    end

    context "when not enough resources available" do
      before do
        resource_manager.stub(:could_reserve?) { false }
        resource_manager.stub(:get_constrained_resource) { "memory" }
      end

      it "does not register staging task" do
        staging_task_registry.should_not_receive(:register)
        subject.handle(message)
      end

      it "does not start staging task" do
        staging_task.should_not_receive(:start)
        subject.handle(message)
      end

      it "responds to staging request with the error" do
        nats_mock.should_receive(:publish).with("respond-to", JSON.dump(
          "task_id" => staging_task.task_id,
          "error" => "Not enough memory resources available",
        ))
        subject.handle(message)
      end
    end
  end

  describe "#handle_stop" do
    let(:message) { double(:message, :data => {"app_id" => "some_app_id"}) }

    before do
      staging_task_registry.register(staging_task)
    end

    it "stops all staging tasks with the given id" do
      staging_task.should_receive(:stop)
      subject.handle_stop(message)
    end

    describe "when an error occurs" do
      it "catches the error since this is the top level" do
        staging_task.stub(:stop).and_raise(RuntimeError, "Some Terrible Error")
        expect { subject.handle_stop(message) }.to_not raise_error
      end
    end
  end
end
