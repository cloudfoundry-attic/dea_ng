# coding: UTF-8

require "steno"
require "steno/core_ext"
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
          destroy_crash_artifacts(instance_id)
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
            logger.info("Removing crash for #{instance.application_name}")

            destroy_crash_artifacts(instance.instance_id)
            unregister(instance)
          end
        end
      end
    end

    private

    attr_reader :reap_crash_queue
    attr_reader :reap_crash_thread

    def destroy_crash_artifacts(instance_id)
      @reap_crash_queue ||= Queue.new
      @reap_crash_thread ||= Thread.new do
        while crash_path = @reap_crash_queue.pop
          logger.debug("Removing path #{crash_path}")

          begin
            FileUtils.rm_rf(crash_path)
          rescue => e
            logger.log_exception(e)
          end
        end
      end

      crash_path = File.join(config.crashes_path, instance_id)
      reap_crash_queue.push(crash_path)
    end
  end
end
