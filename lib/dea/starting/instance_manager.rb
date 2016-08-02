require "dea/starting/instance"

module Dea
  class InstanceManager

    EXIT_REASON_CRASHED = "CRASHED"

    def initialize(bootstrap, message_bus)
      @bootstrap = bootstrap
      @message_bus = message_bus
      @instance_count = 0
      @creation_count = 0
    end

    def create_instance(attributes)
      @creation_count += 1
      instance = Instance.new(bootstrap, attributes)
      bootstrap.instance_logger.info("Creating #{@creation_count}: Instance #{instance.instance_id} Application #{instance.application_id}") if bootstrap.instance_logger


      begin
        instance.validate
      rescue => error
        logger.warn("Error validating instance: ", instance: instance, error: error)
        return
      end

      instance.setup

      instance.on(Instance::Entering.new(:crashed)) do
        bootstrap.instance_logger.info("CRASHED: Instance #{instance.instance_id} Application #{instance.application_id}") if bootstrap.instance_logger
        send_crashed_message(instance)
        bootstrap.snapshot.save
      end

      instance.on(Instance::Entering.new(:running)) do
        bootstrap.instance_logger.info("RUNNING: Instance #{instance.instance_id} Application #{instance.application_id}") if bootstrap.instance_logger
        bootstrap.send_heartbeat()
        bootstrap.router_client.register_instance(instance)
        bootstrap.snapshot.save
      end

      instance.on(Instance::Exiting.new(:running)) do
        bootstrap.instance_logger.info("EXITING: Instance #{instance.instance_id} Application #{instance.application_id}") if bootstrap.instance_logger
        bootstrap.router_client.unregister_instance(instance)
      end

      instance.on(Instance::Entering.new(:stopping)) do
        bootstrap.instance_logger.info("STOPPING: Instance #{instance.instance_id} Application #{instance.application_id}") if bootstrap.instance_logger
        bootstrap.snapshot.save
      end

      instance.on(Instance::Entering.new(:stopped)) do
        bootstrap.instance_logger.info("STOPPED: Instance #{instance.instance_id} Application #{instance.application_id}") if bootstrap.instance_logger
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

      bootstrap.instance_logger.info("Created #{@registration_count}: Instance #{instance.instance_id} Application #{instance.application_id}") if bootstrap.instance_logger

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
