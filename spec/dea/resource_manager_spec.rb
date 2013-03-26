# coding: UTF-8

require "spec_helper"
require "dea/resource_manager"
require "dea/instance_registry"
require "dea/instance"

describe Dea::ResourceManager do
  let(:bootstrap) { mock(:bootstrap, :config => { }) }
  let(:instance_registry) { Dea::InstanceRegistry.new({ }) }

  let(:memory_mb) { 600 }
  let(:memory_overcommit_factor) { 4 }
  let(:disk_mb) { 4000 }
  let(:disk_overcommit_factor) { 2 }

  let(:manager) do
    Dea::ResourceManager.new(instance_registry, {
      "memory_mb" => memory_mb,
      "memory_overcommit_factor" => memory_overcommit_factor,
      "disk_mb" => disk_mb,
      "disk_overcommit_factor" => disk_overcommit_factor
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
      let(:instances) { [] }

      it "returns the full memory capacity" do
        manager.remaining_memory.should eql(memory_mb * memory_overcommit_factor)
      end
    end

    it "returns the correct remaining memory" do
      reserved_in_bytes = instances[0].memory_limit_in_bytes + instances[1].memory_limit_in_bytes
      reserved_in_mb = reserved_in_bytes / 1024 / 1024
      manager.remaining_memory.should eql(
        (memory_mb * memory_overcommit_factor) - reserved_in_mb
      )
    end
  end

  describe "#remaining_disk" do
    context "when no instances are registered" do
      let(:instances) { [] }

      it "returns the full disk capacity" do
        manager.remaining_disk.should eql(disk_mb * disk_overcommit_factor)
      end
    end

    it "returns the correct remaining disk" do
      reserved_in_bytes = instances[0].disk_limit_in_bytes + instances[1].disk_limit_in_bytes
      reserved_in_mb = reserved_in_bytes / 1024 / 1024
      manager.remaining_disk.should eql(
        (disk_mb * disk_overcommit_factor) - reserved_in_mb
      )
    end
  end

  describe "could_reserve?" do
    context "when the given amounts of memory and disk are available \
             (including extra 'headroom' memory)" do
      it "can reserve" do
        manager.could_reserve?(memory_mb * memory_overcommit_factor - 600, 1).should be_true
      end
    end

    context "when too much memory is being used" do
      it "can't reserve" do
        manager.could_reserve?(memory_mb * memory_overcommit_factor, 1).should be_false
      end
    end

    context "when too much disk is being used" do
      it "can't reserve" do
        manager.could_reserve?(1, disk_mb * disk_overcommit_factor).should be_false
      end
    end
  end
end
