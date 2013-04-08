# coding: UTF-8

require "spec_helper"
require "dea/resource_manager"
require "dea/instance_registry"
require "dea/staging_task_registry"
require "dea/staging_task"
require "dea/instance"

describe Dea::ResourceManager do
  let(:staging_config) {
    {
      "memory_limit_mb" => 256,
      "disk_limit_mb" => 1024
    }
  }
  let(:bootstrap) do
    mock(:bootstrap, :config => {
      "staging" => staging_config
    })
  end
  let(:dir_server) { mock(:dir_server) }
  let(:instance_registry) { Dea::InstanceRegistry.new({}) }
  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }

  let(:memory_mb) { 600 }
  let(:memory_overcommit_factor) { 4 }
  let(:disk_mb) { 4000 }
  let(:disk_overcommit_factor) { 2 }
  let(:nominal_memory_capacity) { memory_mb * memory_overcommit_factor }
  let(:nominal_disk_capacity) { disk_mb * disk_overcommit_factor }

  let(:manager) do
    Dea::ResourceManager.new(instance_registry, staging_task_registry, {
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

  let(:staging_tasks) do
    [
      Dea::StagingTask.new(bootstrap, dir_server, valid_staging_attributes),
      Dea::StagingTask.new(bootstrap, dir_server, valid_staging_attributes),
      Dea::StagingTask.new(bootstrap, dir_server, valid_staging_attributes)
    ]
  end

  before do
    instances.each { |i| instance_registry.register(i) }
    staging_tasks.each { |t| staging_task_registry.register(t) }
  end

  describe "#remaining_memory" do
    context "when no instances or staging tasks are registered" do
      let(:instances) { [] }
      let(:staging_tasks) { [] }

      it "returns the full memory capacity" do
        manager.remaining_memory.should eql(memory_mb * memory_overcommit_factor)
      end
    end

    it "returns the correct remaining memory" do
      manager.remaining_memory.should eql(
        nominal_memory_capacity -
        (staging_config["memory_limit_mb"] * 3) -
        (
          instances[0].memory_limit_in_bytes +
          instances[1].memory_limit_in_bytes
        ) / (1024 * 1024)
      )
    end
  end

  describe "#remaining_disk" do
    context "when no instances are registered" do
      let(:instances) { [] }
      let(:staging_tasks) { [] }

      it "returns the full disk capacity" do
        manager.remaining_disk.should eql(nominal_disk_capacity)
      end
    end

    it "returns the correct remaining disk" do
      reserved_in_bytes = instances[0].disk_limit_in_bytes + instances[1].disk_limit_in_bytes
      reserved_in_mb = reserved_in_bytes / 1024 / 1024
      manager.remaining_disk.should eql(
        nominal_disk_capacity - 3 * staging_config["disk_limit_mb"] - reserved_in_mb
      )
    end
  end

  describe "could_reserve?" do
    let(:remaining_memory) do
      reserved_for_instances = (instances[0].memory_limit_in_bytes + instances[1].memory_limit_in_bytes) / 1024 / 1024
      reserved_for_staging = 3 * staging_config["memory_limit_mb"]
      nominal_memory_capacity - reserved_for_instances - reserved_for_staging
    end

    let(:remaining_disk) do
      reserved_for_instances = (instances[0].disk_limit_in_bytes + instances[1].disk_limit_in_bytes) / 1024 / 1024
      reserved_for_staging = 3 * staging_config["disk_limit_mb"]
      nominal_disk_capacity - reserved_for_instances - reserved_for_staging
    end

    context "when the given amounts of memory and disk are available \
             (including extra 'headroom' memory)" do
      it "can reserve" do
        manager.could_reserve?(remaining_memory - 1, remaining_disk - 1).should be_true
      end
    end

    context "when too much memory is being used" do
      it "can't reserve" do
        manager.could_reserve?(remaining_memory, 1).should be_false
      end
    end

    context "when too much disk is being used" do
      it "can't reserve" do
        manager.could_reserve?(1, nominal_disk_capacity).should be_false
      end
    end
  end
end
