require "dea/starting/instance"

module Dea
  class InstanceManager

    EXIT_REASON_CRASHED = "CRASHED"

    def initialize(bootstrap, message_bus)
      @bootstrap = bootstrap
      @message_bus = message_bus
    end

    def create_instance(attributes)
      instance = Instance.new(bootstrap, attributes)

      begin
        instance.validate
      rescue => error
        logger.warn("Error validating instance: ", instance: instance, error: error)
        return
      end

      instance.setup

      instance.on(Instance::Entering.new(:crashed)) do
        send_crashed_message(instance)
        bootstrap.snapshot.save
      end

      instance.on(Instance::Entering.new(:running)) do
        bootstrap.send_heartbeat()
        bootstrap.router_client.register_instance(instance)
        bootstrap.snapshot.save
      end

      instance.on(Instance::Exiting.new(:running)) do
        bootstrap.router_client.unregister_instance(instance)
      end

      instance.on(Instance::Entering.new(:stopping)) do
        bootstrap.snapshot.save
      end

      instance.on(Instance::Entering.new(:stopped)) do
        bootstrap.instance_registry.unregister(instance)
        EM.next_tick do
          instance.destroy
          bootstrap.snapshot.save
        end
      end

      resource_manager = bootstrap.resource_manager
      if resource_manager.could_reserve?(attributes["limits"]["mem"], attributes["limits"]["disk"])
        bootstrap.instance_registry.register(instance)
      else
        constrained_resource = resource_manager.get_constrained_resource(attributes["limits"]["mem"],
                                                                         attributes["limits"]["disk"])
        bootstrap.instance_registry.register(instance)

        logger.error("instance.start.insufficient-resource",
                     app: instance.attributes["application_id"],
                     instance: instance.attributes["instance_index"],
                     constrained_resource: constrained_resource)

        instance.exit_description = "Not enough #{constrained_resource} resource available."
        instance.state = Instance::State::CRASHED
        return nil
      end

      instance
    end

    private

    attr_reader :bootstrap

    def send_crashed_message(instance)
      msg = Dea::Protocol::V1::ExitMessage.generate(instance, EXIT_REASON_CRASHED)
      @message_bus.publish("droplet.exited", msg)
    end
  end
end
