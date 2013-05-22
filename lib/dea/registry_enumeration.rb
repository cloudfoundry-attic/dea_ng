module Dea
  module RegistryEnumeration
    def reserved_memory_bytes
      reduce(0) { |sum, task| sum + task.memory_limit_in_bytes }
    end

    def used_memory_bytes
      reduce(0) { |sum, task| sum + task.used_memory_in_bytes }
    end

    def reserved_disk_bytes
      reduce(0) { |sum, task| sum + task.disk_limit_in_bytes }
    end
  end
end