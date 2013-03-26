# coding: UTF-8

require "spec_helper"
require "dea/resource_manager"
require "dea/instance_registry"
require "dea/instance"

describe Dea::ResourceManager do
  let(:bootstrap) { mock(:bootstrap, :config => { }) }
  let(:instance_registry) { Dea::InstanceRegistry.new({ }) }

  let(:manager) do
    Dea::ResourceManager.new(instance_registry, {
      "memory_mb" => 600,
      "disk_mb" => 4000,
      "num_instances" => 100
    })
  end

  let(:instances) do
    [
      Dea::Instance.new(bootstrap, {
        "limits" => { "mem" => 200, "disk" => 2000, "fds" => 1 }
      }),
      Dea::Instance.new(bootstrap, {
        "limits" => { "mem" => 300, "disk" => 1000, "fds" => 1 }
      })
    ]
  end

  before do
    instances.each do |instance|
      instance_registry.register(instance)
    end
  end

  describe "#remaining_memory" do
    context "when no instances are registered" do
      before do
        instance_registry.each { |i| instance_registry.unregister(i) }
      end

      it "returns the full capacity" do
        manager.remaining_memory.should eql(600)
      end
    end

    it "returns the correct remaining memory" do
      reserved_in_bytes = instances[0].memory_limit_in_bytes + instances[1].memory_limit_in_bytes
      reserved_in_mb = reserved_in_bytes / 1024 / 1024
      manager.remaining_memory.should eql(600 - reserved_in_mb)
    end
  end

  describe "could_reserve?" do
    context "when the given amounts of memory and disk are available" do
      it "can reserve" do
        manager.could_reserve?(10, 900).should be_true
      end
    end

    context "when too much memory is being used" do
      it "can't reserve" do
        manager.could_reserve?(100, 900).should be_false
      end
    end

    context "when too much disk is being used" do
      it "can't reserve" do
        manager.could_reserve?(10, 1100).should be_false
      end
    end
  end
end
