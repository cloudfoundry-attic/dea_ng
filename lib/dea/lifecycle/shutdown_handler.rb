class ShutdownHandler
  def initialize(message_bus, locator_responders, instance_registry, staging_registry, droplet_registry, directory_server, logger)
    @message_bus = message_bus
    @locator_responders = locator_responders
    @instance_registry = instance_registry
    @staging_registry = staging_registry
    @droplet_registry = droplet_registry
    @directory_server = directory_server
    @logger = logger
  end

  def shutdown!(goodbye_message)
    return if shutting_down?
    @shutting_down = true

    remove_droplets
    @message_bus.publish("dea.shutdown", goodbye_message)
    @locator_responders.each(&:stop)
    @message_bus.stop
    @directory_server.unregister

    tasks_to_stop.dup.each do |task_to_stop|
      task_to_stop.stop do |error|
        tasks_to_stop.delete(task_to_stop)

        if error
          @logger.warn("#{task_to_stop} failed to stop: #{error}")
        else
          @logger.debug("#{task_to_stop} exited")
        end

        flush_message_bus_and_terminate if tasks_to_stop.empty?
      end
    end

    flush_message_bus_and_terminate if tasks_to_stop.empty?
  end

  private

  def tasks_to_stop
    @pending_stops ||= Set.new(@instance_registry.instances + @staging_registry.tasks)
  end

  def flush_message_bus_and_terminate
    @logger.info("All instances and staging tasks stopped, exiting.")
    @message_bus.flush { terminate }
  end

  def remove_droplets
    @droplet_registry.keys.each do |sha|
      logger.debug("Removing droplet for sha=#{sha}")

      @droplet_registry[sha].destroy
    end
  end

  def shutting_down?
    @shutting_down
  end

  # So we can test shutdown()
  def terminate
    exit
  end
end
