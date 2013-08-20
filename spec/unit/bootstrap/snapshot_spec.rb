# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe "snapshot" do
  include_context "bootstrap_setup"

  before do
    bootstrap.unstub(:save_snapshot)

    bootstrap.unstub(:setup_directories)
    bootstrap.setup_directories
  end

  describe "save" do
    before do
      instances = []

      # Create an instance in every state
      Dea::Instance::State.constants.each do |name|
        state = Dea::Instance::State.const_get(name)

        instance = Dea::Instance.new(bootstrap, valid_instance_attributes)
        instance.stub(:validate)
        instance.state = state
        instances << instance
      end

      bootstrap.stub(:instance_registry).and_return(instances)
    end

    it "should save a snapshot so loggregator know what apps are running" do
      bootstrap.save_snapshot

      snapshot = ::Yajl::Parser.parse(File.read(bootstrap.snapshot_path))
      snapshot["time"].should be_within(1.0).of(Time.now.to_f)

      expected_states = [
        Dea::Instance::State::RUNNING,
        Dea::Instance::State::CRASHED,
      ].sort.uniq

      actual_states = snapshot["instances"].map do |attributes|
        attributes["state"]
      end.sort.uniq

      actual_states.should == expected_states
    end

    it "has a snapshot with expected attributes so loggregator can process the json correctly" do
      bootstrap.save_snapshot

      snapshot = ::Yajl::Parser.parse(File.read(bootstrap.snapshot_path))
      snapshot["time"].should be_within(1.0).of(Time.now.to_f)

      instance_keys = snapshot["instances"].first.keys
      instance_keys.should =~ %w(
        application_id
        warden_container_path
        warden_job_id
        instance_index
        state
        warden_host_ip
        instance_host_port
        instance_id
      )
    end
  end
end
