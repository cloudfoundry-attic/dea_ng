# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe "snapshot" do
  include_context "bootstrap_setup"

  before do
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
      bootstrap.snapshot_save

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

        bootstrap.
          should_receive(:create_instance) do |attr|
            attr.should_not include("state")

            # Return mock instance
            instance
          end
      end

      bootstrap.snapshot_load
    end
  end
end
