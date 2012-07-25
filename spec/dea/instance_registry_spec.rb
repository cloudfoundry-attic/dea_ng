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
end
