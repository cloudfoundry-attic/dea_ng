require "dea/staging/staging_task"
require "dea/starting/instance"

module Dea
  class Snapshot
    def initialize(staging_task_registry, instance_registry, base_dir, instance_manager)
      @staging_task_registry = staging_task_registry
      @instance_registry = instance_registry
      @base_dir = base_dir
      @instance_manager = instance_manager
    end

    def path
      File.join(base_dir, "db", "instances.json")
    end

    def save
      start = Time.now

      instances = instance_registry.select do |i|
        [
          Dea::Instance::State::STARTING,
          Dea::Instance::State::STOPPING,
          Dea::Instance::State::RUNNING,
          Dea::Instance::State::CRASHED,
        ].include?(i.state)
      end

      snapshot = {
        "time" => start.to_f,
        "instances" => instances.map(&:snapshot_attributes),
        "staging_tasks" => staging_task_registry.map(&:snapshot_attributes)
      }

      file = Tempfile.new("instances", File.join(base_dir, "tmp"))
      file.write(::Yajl::Encoder.encode(snapshot, :pretty => true))
      file.close

      FileUtils.mv(file.path, path)

      logger.debug("Saving snapshot took: %.3fs" % [Time.now - start])
    end

    def load
      return unless File.exist?(path)

      start = Time.now

      snapshot = ::Yajl::Parser.parse(File.read(path))
      snapshot ||= {}

      if snapshot["instances"]
        snapshot["instances"].each do |attributes|
          instance_state = attributes.delete("state")
          instance = instance_manager.create_instance(attributes)
          next unless instance

          # Ignore instance if it doesn't validate
          begin
            instance.validate
          rescue => error
            logger.warn("Error validating instance: #{error.message}")
            next
          end

          # Enter instance state via "RESUMING" to trigger the right transitions
          instance.state = Instance::State::RESUMING
          instance.state = instance_state
        end

        logger.debug("Loading snapshot took: %.3fs" % [Time.now - start])
      end
    end

    private
    attr_reader :staging_task_registry, :instance_registry, :base_dir, :instance_manager

    def logger
      @logger ||= Steno::Logger.new("Snapshot", Steno.config.sinks, :level => Steno.config.default_log_level)
    end
  end
end
