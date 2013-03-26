# coding: UTF-8

module Dea
  class ResourceManager
    DEFAULT_CONFIG = {
      "memory_mb" => 8 * 1024,
      "memory_overcommit_factor" => 1,
      "disk_mb" => 16 * 1024 * 1024,
      "disk_overcommit_factor" => 1,
    }

    def initialize(instance_registry, config = {})
      config = DEFAULT_CONFIG.merge(config)
      @memory_capacity = config["memory_mb"]
      @disk_capacity = config["disk_mb"]
      @instance_registry = instance_registry
    end

    attr_reader :memory_capacity, :disk_capacity

    def could_reserve?(memory, disk)
      (remaining_memory > memory) && (remaining_disk > disk)
    end

    def reserved_memory
      bytes_to_mb(@instance_registry.total_reserved_memory_in_bytes)
    end

    def used_memory
      bytes_to_mb(@instance_registry.total_used_memory_in_bytes)
    end

    def reserved_disk
      bytes_to_mb(@instance_registry.total_reserved_disk_in_bytes)
    end

    def remaining_memory
      memory_capacity - reserved_memory
    end

    def remaining_disk
      disk_capacity - reserved_disk
    end

    private

    def bytes_to_mb(bytes)
      bytes / (1024 * 1024)
    end
  end
end
