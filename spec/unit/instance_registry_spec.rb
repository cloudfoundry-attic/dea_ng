# coding: UTF-8

require "spec_helper"
require "dea/config"
require "dea/instance"
require "dea/instance_registry"

describe Dea::InstanceRegistry do
  let(:bootstrap) { mock("bootstrap", :config => {}) }
  let(:instance_registry) { Dea::InstanceRegistry.new }
  let(:instance) { Dea::Instance.new(bootstrap, { "application_id" => 1 }) }
  let(:instance1) { Dea::Instance.new(bootstrap, { "application_id" => 1}) }

  it_behaves_like :handles_registry_enumerations

  describe "#register" do
    before :each do
      instance_registry.register(instance)
    end

    it "should allow one to lookup the instance by id" do
      instance_registry.lookup_instance(instance.instance_id).should == instance
    end

    it "should allow one to lookup the instance by application id" do
      instances = instance_registry.instances_for_application(instance.application_id)
      instances.should == { instance.instance_id => instance }
    end
  end

  describe "#unregister" do
    before :each do
      instance_registry.register(instance)
      instance_registry.unregister(instance)
    end

    it "should ensure the instance cannot be looked up by id" do
      instance_registry.lookup_instance(instance.instance_id).should be_nil
    end

    it "should ensure the instance cannot be looked up by application id" do
      instance_registry.instances_for_application(instance.application_id).should == {}
    end
  end

  describe "#instances_for_application" do
    before :each do
      instance_registry.register(instance)
      instance_registry.register(instance1)
    end

    it "should return all registered instances for the supplied application id" do
      instances = instance_registry.instances_for_application(instance.application_id)
      instances.should == {
        instance.instance_id => instance,
        instance1.instance_id => instance1,
      }
    end
  end

  describe "#app_id_to_count" do
    context "when there are no instances" do
      it "is an empty hash" do
        expect(instance_registry.app_id_to_count).to eq({})
      end
    end

    context "when there are instances" do
      before do
        instance_registry.register(Dea::Instance.new(bootstrap, { "application_id" => "app1" }))
        instance_registry.register(Dea::Instance.new(bootstrap, { "application_id" => "app1" }))
      end

      it "is a hash of the number of instances per app id" do
        expect(instance_registry.app_id_to_count).to eq({
          "app1" => 2
        })
      end
    end
  end

  describe "#each" do
    before :each do
      instance_registry.register(instance)
      instance_registry.register(instance1)
    end

    it "should iterate over all registered instances" do
      seen = []
      instance_registry.each { |instance| seen << instance }
      seen.should == [instance, instance1]
    end
  end

  describe "#empty?" do
    it "should return true if no instances are registered" do
      instance_registry.empty?.should be_true
    end

    it "should return false if any instances are registered" do
      instance_registry.register(instance)
      instance_registry.empty?.should be_false
    end
  end

  describe "#instances" do
    before :each do
      instance_registry.register(instance)
      instance_registry.register(instance1)
    end

    it "should return all registered instances" do
      instance_registry.instances.should =~ [instance1, instance]
    end
  end

  describe "crash reaping of orphans" do
    include_context "tmpdir"

    let(:config) do
      Dea::Config.new({
        "base_dir" => tmpdir,
      })
    end

    let(:instance_registry) { Dea::InstanceRegistry.new(config) }

    it "should reap orphaned crashes" do
      instance = register_crashed_instance(nil)

      em do
        instance_registry.reap_orphaned_crashes

        after_defers_finish do
          instance.should be_reaped

          done
        end
      end
    end

    it "should ignore referenced crashes" do
      instance = register_crashed_instance(instance_registry)

      em do
        instance_registry.reap_orphaned_crashes

        after_defers_finish do
          instance.should_not be_reaped

          done
        end
      end
    end
  end

  describe "crash reaping" do
    include_context "tmpdir"

    let(:config) do
      Dea::Config.new({
        "base_dir" => tmpdir,
        "crash_lifetime_secs" => crash_lifetime,
      })
    end

    let(:instance_registry) { Dea::InstanceRegistry.new(config) }
    let(:crash_lifetime) { 10 }
    let(:time_of_check) { 20 }

    before do
      x = Time.now
      x.stub(:to_i).and_return(time_of_check)
      Time.stub(:now).and_return(x)
    end

    it "should reap crashes that are too old" do
      instances = [15, 5].each_with_index.map do |age, ii|
        register_crashed_instance(instance_registry,
                                  :application_id => ii,
                                  :state_timestamp => age)
      end

      em do
        instance_registry.reap_crashes

        after_defers_finish do
          instances[0].should_not be_reaped
          instances[1].should be_reaped

          done
        end
      end
    end

    it "should reap all but the most recent crash for an app" do
      instances = [15, 14, 13].each_with_index.map do |age, ii|
        register_crashed_instance(instance_registry,
                                  :application_id => 0,
                                  :state_timestamp => age)
      end

      em do
        instance_registry.reap_crashes

        after_defers_finish do
          instances[0].should_not be_reaped
          instances[1].should be_reaped
          instances[2].should be_reaped

          done
        end
      end
    end
  end

  describe "crash reaping under disk pressure" do
    include_context "tmpdir"

    let(:config) do
      Dea::Config.new({
        "base_dir" => tmpdir,
      })
    end

    let(:instance_registry) { Dea::InstanceRegistry.new(config) }

    it "should reap under disk pressure" do
      instance_registry.should_receive(:disk_pressure?).and_return(true, false)

      instances = 2.times.map do |i|
        register_crashed_instance(instance_registry,
                                  :state_timestamp => i)
      end

      em do
        instance_registry.reap_crashes_under_disk_pressure

        after_defers_finish do
          instances[0].should be_reaped
          instances[1].should_not be_reaped

          done
        end
      end
    end

    it "should continue reaping while under disk pressure" do
      instance_registry.stub(:disk_pressure?).and_return(true)

      instances = 2.times.map do |i|
        register_crashed_instance(instance_registry,
                                  :state_timestamp => i)
      end

      em do
        instance_registry.reap_crashes_under_disk_pressure

        after_defers_finish do
          instances[0].should be_reaped
          instances[1].should be_reaped

          done
        end
      end
    end
  end

  describe "#disk_pressure?" do
    include_context "tmpdir"

    let(:config) do
      Dea::Config.new({
        "base_dir" => tmpdir,
        "crash_block_usage_ratio_threshold" => 0.5,
        "crash_inode_usage_ratio_threshold" => 0.5,
      })
    end

    let(:instance_registry) { Dea::InstanceRegistry.new(config) }

    it "should return false when #stat raises" do
      Sys::Filesystem.should_receive(:stat).and_raise("error")

      instance_registry.disk_pressure?.should be_false
    end

    it "should return false when thresholds are not reached" do
      stat = double
      stat.stub(:blocks => 10, :blocks_free => 8)
      stat.stub(:files => 10, :files_free => 8)

      Sys::Filesystem.should_receive(:stat).and_return(stat)

      instance_registry.disk_pressure?.should be_false
    end

    it "should return true when block threshold is reached" do
      stat = double
      stat.stub(:blocks => 10, :blocks_free => 2)
      stat.stub(:files => 10, :files_free => 8)

      Sys::Filesystem.should_receive(:stat).and_return(stat)

      instance_registry.disk_pressure?.should be_true
    end

    it "should return true when inode threshold is reached" do
      stat = double
      stat.stub(:blocks => 10, :blocks_free => 8)
      stat.stub(:files => 10, :files_free => 2)

      Sys::Filesystem.should_receive(:stat).and_return(stat)

      instance_registry.disk_pressure?.should be_true
    end
  end

  def register_crashed_instance(instance_registry, options = {})
    instance = Dea::Instance.new(bootstrap, {})
    instance.state = Dea::Instance::State::CRASHED

    options.each do |key, value|
      instance.stub(key).and_return(value)
    end

    crash_path = File.join(config.crashes_path, instance.instance_id)

    instance.stub(:reaped?) do
      File.directory?(crash_path) == false
    end

    FileUtils.mkdir_p(crash_path)

    instance_registry.register(instance) if instance_registry

    instance
  end
end
