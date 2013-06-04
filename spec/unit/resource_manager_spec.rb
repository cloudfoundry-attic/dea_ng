# coding: UTF-8

require "spec_helper"
require "dea/resource_manager"
require "dea/instance_registry"
require "dea/staging_task_registry"
require "dea/staging_task"
require "dea/instance"

describe Dea::ResourceManager do
  let(:instance_registry) { double(:instance_registry, :reserved_memory_bytes => reserved_instance_memory, :reserved_disk_bytes => reserved_instance_disk) }
  let(:staging_registry) { double(:staging_registry, :reserved_memory_bytes => reserved_staging_memory, :reserved_disk_bytes => reserved_staging_disk) }
  let(:reserved_instance_disk) { 512 }
  let(:reserved_staging_disk) { 1 }
  let(:reserved_instance_memory) { 512 }
  let(:reserved_staging_memory) { 1 }

  let(:memory_mb) { 600 }
  let(:memory_overcommit_factor) { 4 }
  let(:disk_mb) { 4000 }
  let(:disk_overcommit_factor) { 2 }
  let(:nominal_memory_capacity) { memory_mb * memory_overcommit_factor }
  let(:nominal_disk_capacity) { disk_mb * disk_overcommit_factor }

  let(:manager) do
    Dea::ResourceManager.new(instance_registry, staging_registry, {
      "memory_mb" => memory_mb,
      "memory_overcommit_factor" => memory_overcommit_factor,
      "disk_mb" => disk_mb,
      "disk_overcommit_factor" => disk_overcommit_factor
    })
  end

  describe "#remaining_memory" do
    context "when no instances or staging tasks are registered" do
      let(:reserved_instance_memory) { 0 }
      let(:reserved_staging_memory) { 0 }

      it "returns the full memory capacity" do
        manager.remaining_memory.should eql(memory_mb * memory_overcommit_factor)
      end
    end

    it "returns the correct remaining memory" do
      reserved_in_mb = (reserved_instance_memory - reserved_staging_memory) / 1024 / 1024
      manager.remaining_memory.should eql(nominal_memory_capacity - reserved_in_mb)
    end
  end

  describe "#remaining_disk" do
    context "when no instances are registered" do
      let(:reserved_instance_disk) { 0 }
      let(:reserved_staging_disk) { 0 }

      it "returns the full disk capacity" do
        manager.remaining_disk.should eql(nominal_disk_capacity)
      end
    end

    it "returns the correct remaining disk" do
      reserved_in_mb = (reserved_instance_disk - reserved_staging_disk) / 1024 / 1024
      manager.remaining_disk.should eql(nominal_disk_capacity - reserved_in_mb)
    end
  end

  describe "app_id_to_count" do
    it "calls app_id_to_count on the instance_registry" do
      instance_registry.stub(:app_id_to_count => {
        'app1' => 4,
        'app2' => 7,
      })
      expect(manager.app_id_to_count).to eq( {
        'app1' => 4,
        'app2' => 7,
      })
    end
  end

  describe "number_reservable" do
    let(:memory_mb) { 600 }
    let(:memory_overcommit_factor) { 1 }
    let(:disk_mb) { 4000 }
    let(:disk_overcommit_factor) { 1 }

    context "when there is not enough memory to reserve any" do
      it "is 0" do
        manager.number_reservable(10_000, 1).should == 0
      end
    end

    context "when there is not enough disk to reserve any" do
      it "is 0" do
        manager.number_reservable(1, 10_000).should == 0
      end
    end

    context "when there are enough resources for a single reservation" do
      it "is 1" do
        manager.number_reservable(500, 3000).should == 1
      end
    end

    context "when there are enough resources for many reservations" do
      it "is correct" do
        manager.number_reservable(200, 1500).should == 2
        manager.number_reservable(200, 1000).should == 3
      end
    end

    context "when 0 resources are requested" do
      it "returns 0" do
        manager.number_reservable(0, 0).should == 0
      end
    end
  end

  describe "available_memory_ratio" do
    let(:memory_mb) { 40 * 1024 }
    let(:memory_overcommit_factor) { 1 }
    let(:reserved_instance_memory) { 5 * 1024 * 1024 * 1024 }
    let(:reserved_staging_memory) { 5 * 1024 * 1024 * 1024 }

    it "is the ratio of available memory to total memory" do
      manager.available_memory_ratio.should == 0.75
    end
  end

  describe "available_disk_ratio" do
    let(:disk_mb) { 20 * 1024 }
    let(:disk_overcommit_factor) { 1 }
    let(:reserved_instance_disk) { 10 * 1024 * 1024 * 1024 }
    let(:reserved_staging_disk) { 5 * 1024 * 1024 * 1024 }

    it "is the ratio of available disk to total disk" do
      manager.available_disk_ratio.should == 0.25
    end
  end

  describe "could_reserve?" do
    let(:remaining_memory) { nominal_memory_capacity - (reserved_instance_memory - reserved_staging_memory) / 1024 / 1024 }
    let(:remaining_disk) { nominal_disk_capacity - (reserved_instance_disk - reserved_staging_disk) / 1024 / 1024 }

    context "when the given amounts of memory and disk are available (including extra 'headroom' memory)" do
      it "can reserve" do
        manager.could_reserve?(remaining_memory - 1, remaining_disk - 1).should be_true
      end
    end

    context "when too much memory is being used" do
      it "can't reserve" do
        manager.could_reserve?(remaining_memory , 1).should be_false
      end
    end

    context "when too much disk is being used" do
      it "can't reserve" do
        manager.could_reserve?(1, remaining_disk).should be_false
      end
    end
  end
end
