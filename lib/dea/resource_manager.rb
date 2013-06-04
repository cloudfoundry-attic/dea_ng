# coding: UTF-8

module Dea
  class ResourceManager
    DEFAULT_CONFIG = {
      "memory_mb" => 8 * 1024,
      "memory_overcommit_factor" => 1,
      "disk_mb" => 16 * 1024 * 1024,
      "disk_overcommit_factor" => 1,
    }

    def initialize(instance_registry, staging_task_registry, config = {})
      config = DEFAULT_CONFIG.merge(config)
      @memory_capacity = config["memory_mb"] * config["memory_overcommit_factor"]
      @disk_capacity = config["disk_mb"] * config["disk_overcommit_factor"]
      @staging_task_registry = staging_task_registry
      @instance_registry = instance_registry
    end

    attr_reader :memory_capacity, :disk_capacity

    def app_id_to_count
      @instance_registry.app_id_to_count
    end

    def could_reserve?(memory, disk)
      (remaining_memory > memory) && (remaining_disk > disk)
    end

    def number_reservable(memory, disk)
      return 0 if memory.zero? || disk.zero?
      [remaining_memory / memory, remaining_disk / disk].min
    end

    def available_memory_ratio
      1.0 - (reserved_memory.to_f / memory_capacity)
    end

    def available_disk_ratio
      1.0 - (reserved_disk.to_f / disk_capacity)
    end

    def reserved_memory
      total_mb(@instance_registry, :reserved_memory_bytes) +
      total_mb(@staging_task_registry, :reserved_memory_bytes)
    end

    def used_memory
      total_mb(@instance_registry, :used_memory_bytes)
    end

    def reserved_disk
      total_mb(@instance_registry, :reserved_disk_bytes) +
      total_mb(@staging_task_registry, :reserved_disk_bytes)
    end

    def remaining_memory
      memory_capacity - reserved_memory
    end

    def remaining_disk
      disk_capacity - reserved_disk
    end

    private

    def total_mb(registry, resource_name)
      bytes_to_mb(registry.public_send(resource_name))
    end

    def bytes_to_mb(bytes)
      bytes / (1024 * 1024)
    end
  end
end
