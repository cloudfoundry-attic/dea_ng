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

    it "should save a snapshot" do
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
  end
end
