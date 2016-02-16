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

    tasks = Set.new(@instance_registry.instances + @staging_registry.tasks)
    tasks.each do |task|
      task.stop do |error|
        if error
          @logger.warn("#{task} failed to stop: #{error}")
        else
          @logger.debug("#{task} exited")
        end
      end
    end

    flush_message_bus_and_terminate
  end

  def shutting_down?
    @shutting_down
  end

  private

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

  # So we can test shutdown()
  def terminate
    exit
  end
end
