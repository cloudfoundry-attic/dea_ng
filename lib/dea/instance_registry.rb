# coding: UTF-8

require "steno"
require "steno/core_ext"
require "sys/filesystem"
require "thread"

module Dea
  class InstanceRegistry
    DEFAULT_CRASH_LIFETIME_SECS  = 60 * 60
    CRASHES_REAPER_INTERVAL_SECS = 10

    include Enumerable

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
      logger.debug2("Registering instance #{instance.instance_id}")

      @instances[instance.instance_id] = instance

      app_id = instance.application_id
      @instances_by_app_id[app_id] ||= {}
      @instances_by_app_id[app_id][instance.instance_id] = instance

      nil
    end

    def unregister(instance)
      logger.debug2("Removing instance #{instance.instance_id}")

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

    def instances_for_application(app_id)
      @instances_by_app_id[app_id] || {}
    end

    def lookup_instance(instance_id)
      @instances[instance_id]
    end

    def each
      @instances.each { |_, instance| yield instance }
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
          reap_crash(instance_id)
        end
      end
    end

    def reap_crashes
      logger.debug2("Reaping crashes")

      crashes_by_app = Hash.new { |h, k| h[k] = [] }

      select { |i| i.crashed? }.each { |i| crashes_by_app[i.application_id] << i }

      now = Time.now.to_i

      crashes_by_app.each do |app_id, instances|
        # Most recent crashes first
        instances.sort! { |a, b| b.state_timestamp <=> a.state_timestamp }

        instances.each_with_index do |instance, idx|
          secs_since_crash = now - instance.state_timestamp

          # Remove if not most recent, or too old
          if (idx > 0) || (secs_since_crash > crash_lifetime_secs)
            reap_crash(instance.instance_id)
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
          reap_crash(instance.instance_id) do
            # Continue reaping crashes when done
            reap_crashes_under_disk_pressure
          end
        end
      end
    end

    def reap_crash(instance_id, &blk)
      instance = lookup_instance(instance_id)

      message = "Removing crash #{instance_id}"
      message << " (#{instance.application_name})" if instance
      logger.debug(message)

      t = Time.now
      destroy_crash_artifacts(instance_id) do
        logger.debug(message + ": took %.3fs" % (Time.now - t))

        blk.call if blk
      end

      unregister(instance) if instance
    end

    def destroy_crash_artifacts(instance_id, &callback)
      @reap_crash_queue ||= Queue.new
      @reap_crash_thread ||= Thread.new do
        loop do
          crash_path, callback = @reap_crash_queue.pop

          if crash_path.nil?
            break
          end

          logger.debug2("Removing path #{crash_path}")

          begin
            FileUtils.rm_rf(crash_path)
          rescue => e
            logger.log_exception(e)
          end

          EM.next_tick(&callback) if callback
        end
      end

      crash_path = File.join(config.crashes_path, instance_id)
      @reap_crash_queue.push([crash_path, callback])
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
  end
end
