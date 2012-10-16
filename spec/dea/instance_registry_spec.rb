# coding: UTF-8

require "spec_helper"
require "dea/instance"
require "dea/instance_registry"

describe Dea::InstanceRegistry do
  let (:bootstrap) { mock("bootstrap") }
  let (:instance_registry) { Dea::InstanceRegistry.new }
  let (:instance) { Dea::Instance.new(bootstrap, { "application_id" => 1 }) }
  let (:instance1) { Dea::Instance.new(bootstrap, { "application_id" => 1}) }

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

  describe "crash reaping of orphans" do
    include_context "tmpdir"

    let(:config) { Dea::Config.new("base_dir" => tmpdir) }
    let(:instance_registry) { Dea::InstanceRegistry.new(config) }
    let(:instance_id) { "instance_id" }
    let(:crash_path) { File.join(config.crashes_path, instance_id) }

    before do
      FileUtils.mkdir_p(crash_path)
    end

    it "should remove orphaned crashes" do
      instance_registry.reap_orphaned_crashes

      File.directory?(crash_path).should be_false
    end

    it "should ignore referenced crashes" do
      instance = register_crashed_instance(instance_registry,
                                           "instance_id" => instance_id)

      instance_registry.reap_orphaned_crashes

      File.directory?(crash_path).should be_true
    end
  end

  describe "crash reaping" do
    let(:crash_lifetime) { 10 }
    let(:time_of_check) { 20 }

    let(:instance_registry) do
      Dea::InstanceRegistry.new("crash_lifetime_secs" => crash_lifetime)
    end

    before :each do
      x = Time.now
      x.stub(:to_i).and_return(time_of_check)
      Time.stub(:now).and_return(x)
    end

    after :each do
      instance_registry.reap_crashes
    end

    it "should reap crashes that are too old" do
      [15, 5].each_with_index do |age, ii|
        instance = register_crashed_instance(instance_registry,
                                             :application_id => ii,
                                             :state_timestamp => age)
        expect_reap_if(time_of_check - age > crash_lifetime, instance,
                       instance_registry)
      end
    end

    it "should reap all but the most recent crash for an app" do
      [15, 14, 13].each_with_index do |age, ii|
        instance = register_crashed_instance(instance_registry,
                                             :application_id => 0,
                                             :state_timestamp => age)
        expect_reap_if(ii != 0, instance, instance_registry)
      end
    end

    def expect_reap_if(pred, instance, instance_registry)
      method = pred ? :should_receive : :should_not_receive

      instance_registry.send(method, :destroy_crash_artifacts).with(instance.instance_id)
      instance_registry.send(method, :unregister).with(instance)
    end
  end

  def register_crashed_instance(instance_registry, options = {})
    instance = Dea::Instance.new(bootstrap, {})
    instance.state = Dea::Instance::State::CRASHED

    options.each do |key, value|
      instance.stub(key).and_return(value)
    end

    instance_registry.register(instance)
    instance
  end
end
