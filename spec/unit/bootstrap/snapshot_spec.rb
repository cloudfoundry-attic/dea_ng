# coding: UTF-8

require "spec_helper"
require "dea/snapshot"

describe Dea::Snapshot do
  let(:staging_task_registry) { double(:staging_task_registry) }
  let(:instance_registry) { double(:instance_registry, :size => 0) }
  let(:base_dir) { Dir.mktmpdir }
  let(:instance_manager) { double(:instance_manager, :create_instance => nil) }
  let(:bootstrap) { double(:bootstrap, :config => {}) }
  let(:instance_attributes) { {} }

  let(:snapshot) { described_class.new(staging_task_registry, instance_registry, base_dir, instance_manager) }

  before do
    FileUtils.mkdir_p(File.join(base_dir, "tmp"))
    FileUtils.mkdir_p(File.join(base_dir, "db"))
  end

  after do
    FileUtils.rm_rf(base_dir)
  end

  describe "save" do
    let(:staging_task_registry) do
      [ Dea::StagingTask.new(bootstrap, nil, StagingMessage.new(valid_staging_attributes), nil),
        Dea::StagingTask.new(bootstrap, nil, StagingMessage.new(valid_staging_attributes), nil),
      ]
    end

    let(:instance_registry) do
      instances = []

      # Create an instance in every state
      Dea::Instance::State.constants.each do |name|
        state = Dea::Instance::State.const_get(name)

        instance = Dea::Instance.new(bootstrap, valid_instance_attributes(true).merge(instance_attributes))
        allow(instance).to receive(:validate)
        instance.state = state
        instances << instance
      end

      instances
    end

    it "saves the timestamp to the snapshot" do
      snapshot.save

      saved_snapshot = ::Yajl::Parser.parse(File.read(snapshot.path))
      expect(saved_snapshot["time"]).to be_within(1.0).of(Time.now.to_f)
    end

    it "saves the instance registry" do
      snapshot.save

      saved_snapshot = ::Yajl::Parser.parse(File.read(snapshot.path))

      expected_states = [
        Dea::Instance::State::STARTING,
        Dea::Instance::State::STOPPING,
        Dea::Instance::State::RUNNING,
        Dea::Instance::State::CRASHED,
      ].sort.uniq

      actual_states = saved_snapshot["instances"].map do |attributes|
        attributes["state"]
      end.sort.uniq

      expect(actual_states).to eq(expected_states)
    end

    it "saves the staging task registry" do
      snapshot.save

      saved_snapshot = ::Yajl::Parser.parse(File.read(snapshot.path))

      expect(saved_snapshot["staging_tasks"].size).to eq(2)

      expect(saved_snapshot["staging_tasks"][0]["staging_message"]).to include("task_id" => staging_task_registry[0].task_id)

      expect(saved_snapshot["staging_tasks"][1]["staging_message"]).to include("task_id" => staging_task_registry[1].task_id)
    end

    context "instances fields" do
      let(:instance_attributes) { {"health_check_timeout" => 256} }

      before do
        snapshot.save
        saved_snapshot = ::Yajl::Parser.parse(File.read(snapshot.path))
        expect(saved_snapshot["time"]).to be_within(1.0).of(Time.now.to_f)
        @instance = saved_snapshot["instances"].first
      end

      it "has a snapshot with expected attributes so loggregator can process the json correctly" do
        expected_keys = %w(
        application_id
        warden_container_path
        warden_job_id
        instance_index
        state
        syslog_drain_urls
        )

        expect(@instance.keys).to include *expected_keys
      end

      it 'has extra keys for debugging purpose' do
        expected_keys = %w(
          warden_host_ip
          warden_container_ip
          instance_host_port
          instance_id
        )

        expect(@instance.keys).to include *expected_keys
      end

      it 'has correct drain urls' do
        expect(@instance["syslog_drain_urls"]).to eq(%w(syslog://log.example.com syslog://log2.example.com))
      end

      it "has the instance's start timestamp so we can report its uptime" do
        expect(@instance).to have_key("state_starting_timestamp")
      end

      it "has the instance health_check_timeout" do
        expect(@instance["health_check_timeout"]).to eq(256)
      end
    end
  end

  describe "load" do
    context 'with a valid snapshot' do
      before do
        File.open(snapshot.path, "w") do |file|
          saved_snapshot = {
            "instances" => [
              {
                "k1" => "v1",
                "k2" => "v2",
                "state" => "abc",
              },
              {
                "k1" => "v1",
                "k2" => "v2",
                "state" => "abc",
              },
            ],
          }

          file.write(::Yajl::Encoder.encode(saved_snapshot))
        end
      end

      it "should load a snapshot" do
        2.times do
          instance = Dea::Instance.new(bootstrap, valid_instance_attributes)
          allow(instance).to receive(:validate)

          allow(instance).to receive(:state=).ordered.with(Dea::Instance::State::RESUMING)

          allow(instance).to receive(:state=).ordered.with("abc")

          expect(instance_manager).to receive(:create_instance) do |attr|
            expect(attr).to_not include("state")

            # Return mock instance
            instance
          end
        end

        snapshot.load
      end
    end

    context 'when the snapshot does not exist' do
      it 'does not error' do
        expect { snapshot.load }.to_not raise_error
      end
    end

    context 'when the snapshot is invalid' do
      let(:logger) { double(:logger) }

      before do
        allow(snapshot).to receive(:logger) { logger }
        File.open(snapshot.path, "w") do |file|
          file.write('garbage')
        end
      end

      it 'should log an error' do
        expect(logger).to receive(:error).with('Failed to parse', hash_including(:file, :error))
        expect { snapshot.load }.to raise_error Yajl::ParseError
      end
    end
  end

  describe "load the snapshot with STARTING state" do
    before do
      File.open(snapshot.path, "w") do |file|
        saved_snapshot = {
            "instances" => [
                {
                    "k1" => "v1",
                    "k2" => "v2",
                    "state" => "STARTING",
                },
            ],
        }

        file.write(::Yajl::Encoder.encode(saved_snapshot))
      end
    end

    it "the state should be changed to CRASHED" do
      instance = Dea::Instance.new(bootstrap, valid_instance_attributes)
      allow(instance).to receive(:validate)

      allow(instance).to receive(:state=).ordered.with(Dea::Instance::State::RESUMING)

      allow(instance).to receive(:state=).ordered.with(Dea::Instance::State::CRASHED)

      expect(instance_manager).to receive(:create_instance) do |attr|
        expect(attr).to_not include("state")

        # Return mock instance
        instance
      end

      snapshot.load
    end
  end

  describe "load the snapshot with RUNNING state" do
    before do
      File.open(snapshot.path, "w") do |file|
        saved_snapshot = {
            "instances" => [
                {
                    "k1" => "v1",
                    "k2" => "v2",
                    "state" => "Dea::Instance::State::RUNNING",
                },
            ],
        }

        file.write(::Yajl::Encoder.encode(saved_snapshot))
      end
    end

    it "the state should be kept RUNNING" do
      instance = Dea::Instance.new(bootstrap, valid_instance_attributes)
      allow(instance).to receive(:validate)

      allow(instance).to receive(:state=).ordered.with(Dea::Instance::State::RESUMING)

      allow(instance).to receive(:state=).ordered.with("Dea::Instance::State::RUNNING")

      expect(instance_manager).to receive(:create_instance) do |attr|
        expect(attr).to_not include("state")

        # Return mock instance
        instance
      end

      snapshot.load
    end
  end
end
