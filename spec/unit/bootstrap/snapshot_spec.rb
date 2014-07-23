# coding: UTF-8

require "spec_helper"
require "dea/snapshot"

describe Dea::Snapshot do
  let(:staging_task_registry) { double(:staging_task_registry) }
  let(:instance_registry) { double(:instance_registry) }
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
        instance.stub(:validate)
        instance.state = state
        instances << instance
      end

      instances
    end

    it "saves the timestamp to the snapshot" do
      snapshot.save

      saved_snapshot = ::Yajl::Parser.parse(File.read(snapshot.path))
      saved_snapshot["time"].should be_within(1.0).of(Time.now.to_f)
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

      actual_states.should == expected_states
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
        saved_snapshot["time"].should be_within(1.0).of(Time.now.to_f)
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

        @instance.keys.should include *expected_keys
      end

      it 'has extra keys for debugging purpose' do
        expected_keys = %w(
          warden_host_ip
          instance_host_port
          instance_id
        )

        @instance.keys.should include *expected_keys
      end

      it 'has correct drain urls' do
        @instance["syslog_drain_urls"].should =~ %w(syslog://log.example.com syslog://log2.example.com)
      end

      it "has the instance's start timestamp so we can report its uptime" do
        @instance.should have_key("state_starting_timestamp")
      end

      it "has the instance health_check_timeout" do
        @instance["health_check_timeout"].should eq(256)
      end
    end
  end

  describe "load" do
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
        instance.stub(:validate)

        instance.
          should_receive(:state=).
          ordered.
          with(Dea::Instance::State::RESUMING)

        instance.
          should_receive(:state=).
          ordered.
          with("abc")

        instance_manager.should_receive(:create_instance) do |attr|
          attr.should_not include("state")

          # Return mock instance
          instance
        end
      end

      snapshot.load
    end
  end
end
