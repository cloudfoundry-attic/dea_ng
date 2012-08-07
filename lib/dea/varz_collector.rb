require "eventmachine"
require "vcap/component"

module Dea
  class VarzCollector
    class UsageSnapshot

      def self.for_instance(instance)
        new(:used_memory     => instance.used_memory,
            :reserved_memory => instance.memory_limit_in_bytes,
            :used_disk       => instance.used_disk,
            :used_cpu        => instance.computed_pcpu)
      end

      attr_accessor :timestamp
      attr_accessor :used_memory
      attr_accessor :reserved_memory
      attr_accessor :used_disk
      attr_accessor :used_cpu

      def initialize(opts = {})
        @used_memory     = opts[:used_memory]     || 0
        @reserved_memory = opts[:reserved_memory] || 0
        @used_disk       = opts[:used_disk]       || 0
        @used_cpu        = opts[:used_cpu]        || 0
        @timestamp       = Time.now
      end

      def update(other)
        @used_memory     += other.used_memory
        @reserved_memory += other.reserved_memory
        @used_disk       += other.used_disk
        @used_cpu        += other.used_cpu
        @timestamp        = Time.now

        nil
      end

      # Varz from V1 Dea expects memory in kB and disk in bytes
      def to_varz
        { :used_memory     => @used_memory / 1024,
          :reserved_memory => @reserved_memory / 1024,
          :used_disk       => @used_disk,
          :used_cpu        => @used_cpu,
        }
      end
    end

    attr_reader :bootstrap
    attr_reader :update_interval_secs

    def initialize(bootstrap, update_interval_secs = 1)
      @bootstrap = bootstrap

      @update_interval_secs = update_interval_secs
      @started = false
    end

    def start
      return if @started

      @started = true

      EM.add_periodic_timer(update_interval_secs) { update }
    end

    def update
      # Compute aggregate statistics
      by_framework = Hash.new { |h, k| h[k] = UsageSnapshot.new }
      by_runtime   = Hash.new { |h, k| h[k] = UsageSnapshot.new }

      total_mem_used = 0

      bootstrap.instance_registry.each do |instance|
        next unless instance.running? || instance.starting?
        snapshot = UsageSnapshot.for_instance(instance)

        total_mem_used += snapshot.used_memory

        by_framework[instance.framework_name].update(snapshot)
        by_runtime[instance.runtime_name].update(snapshot)
      end

      # Global statistics, these are in MB
      mem = bootstrap.resource_manager.resources["memory"]
      VCAP::Component.varz[:apps_max_memory]      = mem.capacity
      VCAP::Component.varz[:apps_reserved_memory] = mem.used
      VCAP::Component.varz[:apps_used_memory]     = total_mem_used

      # By runtime/framework
      varzify = proc { |k, v| [k, v.to_varz] }
      VCAP::Component.varz[:frameworks] = Hash[by_framework.map(&varzify)]
      VCAP::Component.varz[:runtimes] = Hash[by_runtime.map(&varzify)]

      # Instance listing
      VCAP::Component.varz[:running_apps] =
        bootstrap.instance_registry \
                 .select { |i| i.running? || i.starting? } \
                 .map    { |i| snapshot_instance(i) }

      nil
    end

    private

    # Maintains legacy format used by old DEA.
    def snapshot_instance(instance)
      { :droplet_id      => instance.application_id,
        :instance_id     => instance.instance_id,
        :instance_index  => instance.instance_index,
        :name            => instance.application_name,
        :uris            => instance.application_uris,
        :users           => instance.application_users,
        :version         => instance.application_version,
        :runtime         => instance.runtime_name,
        :framework       => instance.framework_name,
        :mem_quota       => instance.limits["mem"],
        :disk_quota      => instance.limits["disk"],
        :fds_quota       => instance.limits["fds"],
        :state           => instance.state,
        :state_timestamp => instance.state_timestamp.to_i,
        :flapping        => instance.flapping?,
        :start           => instance.start_timestamp,
        :usage           => UsageSnapshot.for_instance(instance).to_varz,
        # :dir, Omitted. Unsure if anyone consumes this.
      }
    end
  end
end
