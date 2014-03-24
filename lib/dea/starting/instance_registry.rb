# coding: UTF-8

require "steno"
require "steno/core_ext"
require "sys/filesystem"
require "thread"
require "dea/loggregator"
require "dea/registry_enumeration"

module Dea
  class InstanceRegistry
    DEFAULT_CRASH_LIFETIME_SECS  = 60 * 60
    CRASHES_REAPER_INTERVAL_SECS = 10

    include Enumerable
    include RegistryEnumeration

    attr_reader :config
    attr_reader :crash_lifetime_secs

    def initialize(config = {})
      @config = config
      @instances = {}
      @instances_by_app_id = {}
      @crash_lifetime_secs = config["crash_lifetime_secs"] || DEFAULT_CRASH_LIFETIME_SECS
    end

    def start_reaper
      EM.add_periodic_timer(CRASHES_REAPER_INTERVAL_SECS) do
        reap_orphaned_crashes
        reap_crashes
        reap_crashes_under_disk_pressure
      end
    end

    def register(instance)
      app_id = instance.application_id
      Dea::Loggregator.emit(app_id,
        "Starting app instance (index #{instance.instance_index}) with guid #{instance.application_id}")
      logger.debug2("Registering instance #{instance.instance_id}")

      add_instance(instance)
    end

    def unregister(instance)
      app_id = instance.application_id

      Dea::Loggregator.emit(app_id,
        "Stopping app instance (index #{instance.instance_index}) with guid #{instance.application_id}")
      logger.debug2("Stopping instance #{instance.instance_id}")

      remove_instance(instance)

      logger.debug2("Stopped instance #{instance.instance_id}")
      Dea::Loggregator.emit(app_id,
        "Stopped app instance (index #{instance.instance_index}) with guid #{instance.application_id}")
    end

    def change_instance_id(instance)
      remove_instance(instance)
      instance.change_instance_id!
      add_instance(instance)
    end

    def instances_for_application(app_id)
      @instances_by_app_id[app_id] || {}
    end

    def lookup_instance(instance_id)
      @instances[instance_id]
    end

    def to_hash
      @instances_by_app_id.each.with_object({}) do |(app_id, instances), hash|
        hash[app_id] =
          instances.each.with_object({}) do |(id, instance), is|
            is[id] = instance.attributes_and_stats
          end
      end
    end

    def app_id_to_count
      app_count = {}
      @instances_by_app_id.each do |app_id, instance_hash|
        app_count[app_id] = instance_hash.size
      end
      app_count
    end

    def undeleted_instances_count
      @instances.size  - select(&:deleted?).size
    end

    def each(&block)
      @instances.each_value(&block)
    end

    def instances
      @instances.values
    end

    def empty?
      @instances.empty?
    end

    def size
      @instances.size
    end

    def reap_orphaned_crashes
      logger.debug2("Reaping orphaned crashes")

      crashes = Dir[File.join(config.crashes_path, "*")].map do |path|
        if File.directory?(path)
          File.basename(path)
        end
      end

      crashes.compact.each do |instance_id|
        instance = lookup_instance(instance_id)

        # Reap if this instance is not referenced
        if instance.nil?
          reap_crash(instance_id, "orphaned")
        end
      end
    end

    def reap_crashes
      logger.debug2("Reaping crashes")

      crashes_by_app = Hash.new { |h, k| h[k] = [] }

      select(&:crashed?).each { |i| crashes_by_app[i.application_id] << i }

      now = Time.now.to_i

      crashes_by_app.each do |app_id, instances|
        # Most recent crashes first
        instances.sort! { |a, b| b.state_timestamp <=> a.state_timestamp }

        instances.each_with_index do |instance, idx|
          secs_since_crash = now - instance.state_timestamp

          # Remove if not most recent, or too old
          if (idx > 0) || (secs_since_crash > crash_lifetime_secs)
            reap_crash(instance.instance_id, "stale")
          end
        end
      end
    end

    def reap_crashes_under_disk_pressure
      logger.debug2("Reaping crashes under disk pressure")

      if disk_pressure?
        instance = select { |i| i.crashed? }.
          sort_by { |i| i.state_timestamp }.
          first

        # Remove oldest crash
        if instance
          reap_crash(instance.instance_id, "disk pressure") do
            # Continue reaping crashes when done
            reap_crashes_under_disk_pressure
          end
        end
      end
    end

    def reap_crash(instance_id, reason = nil, &blk)
      instance = lookup_instance(instance_id)

      data = {
        :instance_id => instance_id,
        :reason      => reason,
      }

      if instance
        data[:application_id]      = instance.application_id
        data[:application_version] = instance.application_version
        data[:application_name]    = instance.application_name
      end

      message = "Removing crash #{instance_id}"

      logger.debug(message, data)
      Dea::Loggregator.emit(data[:application_id], "Removing crash for app with id #{data[:application_id]}")
      t = Time.now
      destroy_crash_artifacts(instance_id) do
        logger.debug(message + ": took %.3fs" % (Time.now - t), data)

        blk.call if blk
      end

      unregister(instance) if instance
    end

    def destroy_crash_artifacts(instance_id, &callback)
      crash_path = File.join(config.crashes_path, instance_id)

      return if crash_path.nil?

      operation = lambda do
        logger.debug2("Removing path #{crash_path}")

        begin
          FileUtils.rm_rf(crash_path)
        rescue => e
          logger.log_exception(e)
        end
      end

      EM.defer(operation, callback)
    end

    def disk_pressure?
      r = false

      begin
        stat = Sys::Filesystem.stat(config.crashes_path)

        block_usage_ratio = Float(stat.blocks - stat.blocks_free) / Float(stat.blocks)
        inode_usage_ratio = Float(stat.files - stat.files_free) / Float(stat.files)

        r ||= block_usage_ratio > config.crash_block_usage_ratio_threshold
        r ||= inode_usage_ratio > config.crash_inode_usage_ratio_threshold

        if r
          logger.debug("Disk usage (block/inode): %.3f/%.3f" % [block_usage_ratio, inode_usage_ratio])
        end

      rescue => e
        logger.log_exception(e)
      end

      r
    end

    def instances_filtered_by_message(message)
      app_id = message.data["droplet"].to_s

      logger.debug2("Filter message for app_id: %s" % app_id, :app_id => app_id)

      instances = instances_for_application(app_id)
      if instances.empty?
        logger.debug2("No instances found for app_id: %s" % app_id, :app_id => app_id)
        return
      end

      make_set = lambda { |key| Set.new(message.data.fetch(key, [])) }
      version = message.data["version"]
      instance_ids = make_set.call("instances") | make_set.call("instance_ids")
      indices = make_set.call("indices")
      states = make_set.call("states").map { |e| Dea::Instance::State.from_external(e) }
      instances.each do |_, instance|
        next if version && (instance.application_version != version)
        next if instance_ids.any? && !instance_ids.include?(instance.instance_id)
        next if indices.any? && !indices.include?(instance.instance_index)
        next if states.any? && !states.include?(instance.state)

        yield(instance)
      end
    end

    private

    def add_instance(instance)
      @instances[instance.instance_id] = instance

      app_id = instance.application_id

      @instances_by_app_id[app_id] ||= {}
      @instances_by_app_id[app_id][instance.instance_id] = instance

      nil
    end

    def remove_instance(instance)
      @instances.delete(instance.instance_id)

      app_id = instance.application_id

      if @instances_by_app_id.has_key?(app_id)
        @instances_by_app_id[app_id].delete(instance.instance_id)

        if @instances_by_app_id[app_id].empty?
          @instances_by_app_id.delete(app_id)
        end
      end

      nil
    end
  end
end
