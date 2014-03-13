require "dea/lifecycle/evacuation_handler"
require "dea/lifecycle/shutdown_handler"
require "dea/utils/platform_compat"

class SignalHandler
  SIGNALS_OF_INTEREST = %W[TERM INT QUIT USR1 USR2].freeze

  def initialize(uuid, local_ip, message_bus, locator_responders, instance_registry, staging_registry, droplet_registry, directory_server, logger, config)
    @uuid = uuid
    @local_ip = local_ip

    @message_bus = message_bus
    @locator_responders = locator_responders
    @instance_registry = instance_registry
    @staging_registry = staging_registry
    @droplet_registry = droplet_registry
    @directory_server = directory_server
    @logger = logger
    @config = config
  end

  def setup(&kernel_trap)
    SIGNALS_OF_INTEREST.each do |signal|
      if PlatformCompat.signal_supported? signal
        kernel_trap.call(signal) do
          @logger.warn "caught SIG#{signal}"
          send("trap_#{signal.downcase}")
        end
      end
    end
  end

  private

  def trap_term
    shutdown
  end

  def trap_int
    shutdown
  end

  # not supported on windows
  def trap_quit
    shutdown
  end

  # not supported on windows
  def trap_usr1
    @message_bus.publish("dea.shutdown", goodbye_message)
    @locator_responders.each(&:stop)
  end

  # not supported on windows
  def trap_usr2
    @evac_handler ||= EvacuationHandler.new(@message_bus, @locator_responders, @instance_registry, @logger, @config)
    can_shutdown = @evac_handler.evacuate!(goodbye_message)

    shutdown if can_shutdown
  end

  def shutdown
    @shutdown_handler ||= ShutdownHandler.new(@message_bus, @locator_responders, @instance_registry, @staging_registry, @droplet_registry, @directory_server, @logger)
    @shutdown_handler.shutdown!(goodbye_message)
  end

  def goodbye_message
    Dea::Protocol::V1::GoodbyeMessage.generate(@uuid, @local_ip, @instance_registry)
  end
end
