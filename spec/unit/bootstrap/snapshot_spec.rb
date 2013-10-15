# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe "snapshot" do
  include_context "bootstrap_setup"

  before do
    bootstrap.unstub(:save_snapshot)
    bootstrap.unstub(:load_snapshot)

    bootstrap.unstub(:setup_directories)
    bootstrap.setup_directories
  end

  describe "save" do
    let(:staging_tasks) do
      [ Dea::StagingTask.new(bootstrap, nil, StagingMessage.new(valid_staging_attributes), nil),
        Dea::StagingTask.new(bootstrap, nil, StagingMessage.new(valid_staging_attributes), nil),
      ]
    end

    let(:instances) do
      instances = []

      # Create an instance in every state
      Dea::Instance::State.constants.each do |name|
        state = Dea::Instance::State.const_get(name)

        instance = Dea::Instance.new(bootstrap, valid_instance_attributes(true))
        instance.stub(:validate)
        instance.state = state
        instances << instance
      end

      instances
    end

    before do
      bootstrap.stub(:instance_registry).and_return(instances)
      bootstrap.stub(:staging_task_registry).and_return(staging_tasks)
    end

    it "saves the timestamp to the snapshot" do
      bootstrap.save_snapshot

      snapshot = ::Yajl::Parser.parse(File.read(bootstrap.snapshot_path))
      snapshot["time"].should be_within(1.0).of(Time.now.to_f)
    end

    it "saves the instance registry" do
      bootstrap.save_snapshot

      snapshot = ::Yajl::Parser.parse(File.read(bootstrap.snapshot_path))

      expected_states = [
        Dea::Instance::State::RUNNING,
        Dea::Instance::State::CRASHED,
      ].sort.uniq

      actual_states = snapshot["instances"].map do |attributes|
        attributes["state"]
      end.sort.uniq

      actual_states.should == expected_states
    end

    it "saves the staging task registry" do
      bootstrap.save_snapshot

      snapshot = ::Yajl::Parser.parse(File.read(bootstrap.snapshot_path))

      expect(snapshot["staging_tasks"].size).to eq(2)

      expect(snapshot["staging_tasks"][0]).to include(
        "task_id" => staging_tasks[0].task_id)

      expect(snapshot["staging_tasks"][1]).to include(
        "task_id" => staging_tasks[1].task_id)
    end

    context 'instances fields' do
      before do
        bootstrap.save_snapshot
        snapshot = ::Yajl::Parser.parse(File.read(bootstrap.snapshot_path))
        snapshot["time"].should be_within(1.0).of(Time.now.to_f)
        @instance = snapshot["instances"].first
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
    end
  end

  describe "load" do
    before do
      File.open(bootstrap.snapshot_path, "w") do |file|
        snapshot = {
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

        file.write(::Yajl::Encoder.encode(snapshot))
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

        bootstrap.should_receive(:create_instance) do |attr|
          attr.should_not include("state")

          # Return mock instance
          instance
        end
      end

      bootstrap.load_snapshot
    end

    it "loads the snapshot on startup" do
      bootstrap.should_receive(:load_snapshot)

      em do
        bootstrap.setup
        bootstrap.start
        EM.stop
      end
    end
  end
end
