require "dea/lifecycle/evacuation_handler"
require "dea/lifecycle/shutdown_handler"

class SignalHandler
  SIGNALS_OF_INTEREST = %W[TERM INT QUIT USR1 USR2].freeze

  def initialize(uuid, local_ip, message_bus, locator_responders, instance_registry, evac_handler, shutdown_handler, logger)
    @uuid = uuid
    @local_ip = local_ip

    @message_bus = message_bus
    @locator_responders = locator_responders
    @instance_registry = instance_registry
    @evac_handler = evac_handler
    @shutdown_handler = shutdown_handler
    @logger = logger
  end

  def setup(&kernel_trap)
    SIGNALS_OF_INTEREST.each do |signal|
      kernel_trap.call(signal) do
        safely do
          @logger.warn("caught SIG#{signal}")
          send("trap_#{signal.downcase}")
        end
      end
    end
  end

  private

  def safely
    Thread.new do
      EM.schedule do
        yield
      end
    end
  end

  def trap_term
    shutdown
  end

  def trap_int
    shutdown
  end

  def trap_quit
    shutdown
  end

  def trap_usr1
    @message_bus.publish("dea.shutdown", goodbye_message)
    @locator_responders.each(&:stop)
  end

  def trap_usr2
    evacuate unless @evac_handler.evacuating?
  end

  def evacuate
    can_shutdown = @evac_handler.evacuate!(goodbye_message)

    if can_shutdown
      shutdown
    else
      EM.add_timer(5) { evacuate }
    end
  end

  def shutdown
    @shutdown_handler.shutdown!(goodbye_message)
  end

  def goodbye_message
    Dea::Protocol::V1::GoodbyeMessage.generate(@uuid, @local_ip, @instance_registry)
  end
end
