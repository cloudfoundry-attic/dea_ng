require "spec_helper"
require "dea/nats"
require "dea/directory_server/directory_server_v2"

require "dea/staging/staging_task_registry"

require "dea/responders/staging"

describe Dea::Responders::Staging do
  let(:snapshot) { double(:snapshot, :save => nil, :load => nil)}
  let(:bootstrap) { double(:bootstrap, :config => config, :snapshot => snapshot, :evac_handler => evac_handler) }
  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }
  let(:staging_error_info) { nil }
  let(:staging_task) do
    double(:staging_task,
           staging_message: staging_message,
           task_id: "task-id",
           task_log: "task-log",
           procfile: {"web" => "npm start"},
           detected_buildpack: nil,
           buildpack_key: nil,
           detected_start_command: "bacofoil",
           droplet_sha1: "some-droplet-sha",
           memory_limit_mb: 1,
           disk_limit_mb: 2,
           error_info: staging_error_info,
          )
  end
  let(:dir_server) { Dea::DirectoryServerV2.new("domain", 1234, config) }
  let(:app_id) { "my_app_id" }
  let(:message) { {"app_id" => app_id, "start_message" => {:command =>"start_message"} } }
  let(:staging_message) { StagingMessage.new(message) }
  let(:resource_manager) { double(:resource_manager, :could_reserve? => true) }
  let(:config) { {"directory_server" => {"file_api_port" => 2345}} }
  let(:evac_handler) { double('evac_handler', :evacuating? => evacuating) }
  let(:evacuating) { false }

  subject { described_class.new(bootstrap, staging_task_registry, dir_server, resource_manager, config) }

  def task_double(buildpack_keys)
    Struct.new(:task_id, :staging_message).new(SecureRandom.uuid, StagingMessage.new("admin_buildpacks" => as_buildpacks(buildpack_keys)))
  end

  def as_buildpacks(buildpack_keys)
    buildpack_keys.map do |key|
      { "url" => "http://www.goolge.com", "key" => key }
    end
  end

  describe "#create_task" do
    before do
      allow(Dea::StagingTask).to receive(:new)
      .with(bootstrap, dir_server, staging_message, [], an_instance_of(Steno::TaggedLogger))
      .and_return(staging_task)
      allow(staging_task).to receive(:after_complete_callback)
      allow(staging_task).to receive(:after_stop_callback)
    end

    it 'logs to the loggregator' do
      emitter = FakeEmitter.new
      Dea::Loggregator.emitter = emitter

      subject.create_task(staging_message)
      expect(emitter.messages[app_id][0]).to eql("Got staging request for app with id #{app_id}")
    end

    it "adds staging task to registry" do
      expect {
        subject.create_task(staging_message)
      }.to change {
        staging_task_registry.registered_task("task-id")
      }.from(nil).to(staging_task)
    end

    it "passes a list of all potentially in-use buildpacks to the staging task" do
      staging_task_registry.register(task_double ["a", "b", "c"])
      staging_task_registry.register(task_double ["b", "c"])
      staging_task_registry.register(task_double ["b", "c", "d", "e"])

      buildpacks_in_use = ["a", "b", "c", "d", "e"].map do |key|
        { url: URI("http://www.goolge.com"), key: key }
      end

      expect(Dea::StagingTask).to receive(:new)
      .with(bootstrap, dir_server, staging_message, buildpacks_in_use, an_instance_of(Steno::TaggedLogger))
      .and_return(staging_task)

      subject.create_task(staging_message)
    end

    it 'saves snapshot' do
      expect(bootstrap.snapshot).to receive(:save)
      subject.create_task(staging_message)
    end

    context 'when there are not enough resources available' do
      before do  
        allow(resource_manager).to receive(:could_reserve?).and_return(false)
        allow(resource_manager).to receive(:get_constrained_resource).and_return("memory")
      end

      it "does not register staging task" do
        expect(staging_task_registry).to_not receive(:register)
        subject.create_task(staging_message)
      end

      it 'responds to the staging message with an insufficient-resource error' do
        expect(subject).to receive(:respond_to_request).with(staging_message, {task_id: "task-id", error: "Not enough memory resources available"})
        subject.create_task(staging_message)
      end
    end

    context 'when there are sufficient resources to stage' do
      it "starts staging task with registered callbacks" do
        expect(staging_task).to receive(:after_complete_callback).ordered
        expect(staging_task).to receive(:after_stop_callback).ordered

        subject.create_task(staging_message)
      end

      describe 'notify completion callback' do
        before do
          allow(bootstrap).to receive(:start_app)
        end

        let(:data) do { 
          :task_id => staging_task.task_id,
          :detected_buildpack => staging_task.detected_buildpack,
          :buildpack_key => staging_task.buildpack_key,
          :droplet_sha1 => staging_task.droplet_sha1,
          :detected_start_command => staging_task.detected_start_command,
          :procfile => staging_task.procfile,
          :app_id => staging_message.app_id,
        } 
        end

        it 'passes a block to clean up the task after completion_response has been sent' do
          called = false
          allow(staging_task).to receive(:after_complete_callback) do |&blk|
            expect(staging_message).to receive(:respond) do |params, &completion_blk|
              expect(params).to eq(data)
              completion_blk.call
              called = true
            end
            blk.call
          end

          subject.create_task(staging_message)
          expect(called).to be true
        end

        it 'responds to the request with the staging result data' do
          called = false
          allow(staging_task).to receive(:after_complete_callback) do |&blk|
            expect(staging_message).to receive(:respond) do |params, &completion_blk|
              expect(params).to eq(data)
              completion_blk.call
            end
            blk.call
            called = true
          end

          subject.create_task(staging_message)
          expect(called).to be true
        end

        it 'unregisters the staging task' do
          called = false
          allow(staging_task).to receive(:after_complete_callback) do |&blk|
            expect {
              expect(staging_message).to receive(:respond) do |_, &completion_blk|
                completion_blk.call
              end
              blk.call
            }.to change {
              staging_task_registry.registered_task("task-id")
            }.from(staging_task).to(nil)
            called = true
          end

          subject.create_task(staging_message)
          expect(called).to be true
        end

        it 'saves snapshot' do
          called = false
          allow(staging_task).to receive(:after_complete_callback) do |&blk|
            expect(bootstrap.snapshot).to receive(:save)
            expect(staging_message).to receive(:respond) do |_, &completion_blk|
              completion_blk.call
            end
            blk.call
            called = true
          end

          subject.create_task(staging_message)
          expect(called).to be true
        end

        context 'and the staging message has a start command' do
          let(:start_message) { message['start_message'].merge('sha1' => staging_task.droplet_sha1) }

          it 'starts the app' do
            called = false
            allow(staging_task).to receive(:after_complete_callback) do |&blk|
              expect(bootstrap).to receive(:start_app).with(start_message)
              expect(staging_message).to receive(:respond) do |_, &completion_blk|
                completion_blk.call
              end
              blk.call
              called = true
            end

            subject.create_task(staging_message)
            expect(called).to be true
          end
        end

        context 'when the dea is evacuating' do
          let(:evacuating) { true }

          it 'does not start the app' do
            called = false
            allow(staging_task).to receive(:after_complete_callback) do |&blk|
              expect(bootstrap).to_not receive(:start_app)
              expect(staging_message).to receive(:respond) do | _, &completion_blk|
                completion_blk.call
              end
              blk.call
              called = true
            end

            subject.create_task(staging_message) 
            expect(called).to be true
          end
        end

        context 'there was en error during staging' do
          let(:error) { "an error occurred" }
          let(:staging_error_info) { "staging error info" }

          before do 
            data[:error] = error
            data[:error_info] = staging_task.error_info
          end

          it 'reports the error in the staging result' do
            called = false

            allow(staging_task).to receive(:after_complete_callback) do |&blk|
              expect(staging_message).to receive(:respond) do | params, &completion_blk|
                expect(params).to eq(data)
                completion_blk.call
              end
              blk.call(error)
              called = true
            end

            subject.create_task(staging_message)
            expect(called).to be true
          end

          it 'does not try to start the app' do
            called = false
            allow(staging_task).to receive(:after_complete_callback) do |&blk|
              expect(bootstrap).to_not receive(:start_app)
              expect(staging_message).to receive(:respond) do | _, &completion_blk|
                completion_blk.call
              end
              blk.call(error)
              called = true
            end

            subject.create_task(staging_message)
            expect(called).to be true
          end
        end
      end

      describe 'notify stop callback' do
        it 'uses the provided request when responding' do
          called = false
          allow(staging_task).to receive(:after_stop_callback) do |&blk|
            expect(staging_message).to receive(:respond).with({task_id: staging_task.task_id, error: nil})
            blk.call
            called = true
          end

          subject.create_task(staging_message)
          expect(called).to be true
        end

        it 'unregisters the staging task' do
          called = false
          allow(staging_task).to receive(:after_stop_callback) do |&blk|
            expect {
              blk.call(staging_message)
            }.to change {
              staging_task_registry.registered_task("task-id")
            }.from(staging_task).to(nil)
            called = true
          end

          subject.create_task(staging_message)
          expect(called).to be true
        end

        it 'saves snapshot' do
          called = false
          allow(staging_task).to receive(:after_stop_callback) do |&blk|
            expect(bootstrap.snapshot).to receive(:save)
            blk.call(staging_message)
            called = true
          end

          subject.create_task(staging_message)

          expect(called).to be true
        end
      end
    end
  end

  describe 'stop_task' do
    before do
      staging_task_registry.register(staging_task)
    end

    it "stops all staging tasks with the given id" do
      expect(staging_task).to receive(:stop)
      subject.stop_task(app_id)
    end

    it 'does not stop any apps if the app_id is not found' do
      expect(staging_task).to_not receive(:stop)
      subject.stop_task('no id')
    end

    describe "when an error occurs" do
      let(:logger) { double(Steno::Logger, :error => nil) }

      before do
        allow(Steno::Logger).to receive(:new).and_return(logger)
        allow(logger).to receive(:tag).and_return(logger)
      end

      it "catches the error and logs it" do
        allow(staging_task).to receive(:stop).and_raise(RuntimeError, "Some Terrible Error")
        expect(logger).to receive(:error).with('staging.handle_stop.failed', any_args)
        expect{ subject.stop_task(app_id) }.to_not raise_error
      end
    end
  end
end