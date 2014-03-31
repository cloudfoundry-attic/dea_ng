class EvacuationHandler
  EXIT_REASON_EVACUATION = "DEA_EVACUATION"

  def initialize(message_bus, locator_responders, instance_registry, logger, config)
    @message_bus = message_bus
    @locator_responders = locator_responders
    @instance_registry = instance_registry
    @logger = logger
    @evacuation_bail_out_time_in_seconds = config["evacuation_bail_out_time_in_seconds"]
  end

  def evacuate!(goodbye_message)
    @start_time = Time.now unless evacuating?

    logger.info("Evacuating (first time: #{!evacuating?}; can shutdown: #{dea_can_shutdown?})")
    send_shutdown_and_stop_advertising(goodbye_message) unless evacuating?
    send_droplet_exited_messages
    transition_instances_to_evacuating

    @evacuation_processed = true

    dea_can_shutdown?
  end

  def evacuating?
    @evacuation_processed
  end

  private

  def send_droplet_exited_messages
    @instance_registry.each do |instance|
      if instance.born? || instance.starting? || instance.resuming? || instance.running?
        msg = Dea::Protocol::V1::ExitMessage.generate(instance, EXIT_REASON_EVACUATION)
        @message_bus.publish("droplet.exited", msg)
      end
    end
  end

  def transition_instances_to_evacuating
    @instance_registry.each do |instance|
      if instance.born? || instance.starting? || instance.resuming? || instance.running?
        @logger.error("Found an unexpected #{instance.state} instance while evacuating") if evacuating?
        instance.state = Dea::Instance::State::EVACUATING
      end
    end
  end

  def send_shutdown_and_stop_advertising(goodbye_message)
    @locator_responders.map(&:stop)
    @message_bus.publish("dea.shutdown", goodbye_message)
  end

  def dea_can_shutdown?
    can_shutdown = @instance_registry.all? do |instance|
      instance.stopping? || instance.stopped? || instance.crashed? || instance.deleted?
    end
    can_shutdown || (@start_time + @evacuation_bail_out_time_in_seconds <= Time.now)
  end
end