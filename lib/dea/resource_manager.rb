# coding: UTF-8

module Dea
  class ResourceManager
    DEFAULT_CONFIG = {
      "memory_mb" => 8 * 1024,
      "memory_overcommit_factor" => 1,

      "disk_mb" => 16 * 1024 * 1024,
      "disk_overcommit_factor" => 1,

      "num_instances" => 16,
    }

    class Resource

      attr_reader :name
      attr_reader :remain
      attr_reader :capacity

      def initialize(name, capacity, overcommit_factor)
        @name = name
        @capacity = capacity * overcommit_factor
        @remain = @capacity
      end

      def reserve(amount)
        if @remain >= amount
          @remain -= amount
          amount
        else
          nil
        end
      end

      def could_reserve?(amount)
        amount <= @remain
      end

      def release(amount)
        @remain += amount
      end

      def used
        @capacity - @remain
      end
    end

    attr_reader :resources

    def initialize(config = {})
      @config = DEFAULT_CONFIG.merge(config)

      @resources = {
        "memory"        => Resource.new("memory", @config["memory_mb"],
                                        @config["memory_overcommit_factor"]),
        "disk"          => Resource.new("disk", @config["disk_mb"],
                                        @config["disk_overcommit_factor"]),
        "num_instances" => Resource.new("num_instances",
                                        @config["num_instances"], 1)
      }
    end

    def could_reserve?(memory, disk, num_instances)
      @resources["memory"].could_reserve?(memory) && \
      @resources["disk"].could_reserve?(disk)     && \
      @resources["num_instances"].could_reserve?(num_instances)
    end

    def reserve(memory, disk, num_instances)
      if could_reserve?(memory, disk, num_instances)
        { "memory" => @resources["memory"].reserve(memory),
          "disk"   => @resources["disk"].reserve(disk),
          "num_instances" => @resources["num_instances"].reserve(num_instances)
        }
      else
        nil
      end
    end

    def release(reservation)
      reservation.each { |name, amount| resources[name].release(amount) }
    end
  end
end
