class EvacuationHandler
  EXIT_REASON_EVACUATION = "DEA_EVACUATION"

  def initialize(bootstrap, message_bus, locator_responders, instance_registry, staging_task_registry, logger, config)
    @bootstrap = bootstrap
    @message_bus = message_bus
    @locator_responders = locator_responders
    @instance_registry = instance_registry
    @staging_task_registry = staging_task_registry
    @logger = logger
    @evacuation_bail_out_time_in_seconds = config["evacuation_bail_out_time_in_seconds"]
  end

  def evacuate!(goodbye_message)
    first_time = !@evacuation_processed
    @evacuation_processed = true

    @start_time ||= Time.now

    send_shutdown_and_stop_advertising(goodbye_message) if first_time
    transition_instances_to_evacuating(first_time)

    can_shutdown = dea_can_shutdown?
    logger.info("Evacuating (first time: #{first_time}; can shutdown: #{can_shutdown})")
    can_shutdown
  end

  def evacuating?
    @evacuation_processed
  end

  private

  def transition_instances_to_evacuating(first_time)
    @instance_registry.each do |instance|
      if instance.born? || instance.starting? || instance.resuming? || instance.running?
        @logger.error("Found an unexpected #{instance.state} instance while evacuating") unless first_time
        instance.state = Dea::Instance::State::EVACUATING
      end
    end
    @bootstrap.send_heartbeat
    EM.cancel_timer(@bootstrap.heartbeat_timer) if first_time
  end

  def send_shutdown_and_stop_advertising(goodbye_message)
    @locator_responders.map(&:stop)
    @message_bus.publish("dea.shutdown", goodbye_message)
  end

  def dea_can_shutdown?
    no_instances = @instance_registry.all? do |instance|
      instance.stopping? || instance.stopped? || instance.crashed?
    end

    (no_instances && @staging_task_registry.tasks.empty?) || (@start_time + @evacuation_bail_out_time_in_seconds <= Time.now)
  end
end
