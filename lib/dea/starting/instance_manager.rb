require "dea/starting/instance"

module Dea
  class InstanceManager

    EXIT_REASON_CRASHED = "CRASHED"

    def initialize(bootstrap)
      @bootstrap = bootstrap
    end

    def create_instance(attributes)
      instance = Instance.new(bootstrap, attributes)

      begin
        instance.validate
      rescue => error
        logger.warn "Error validating instance: #{error.message}"
        return
      end

      instance.on(Instance::Transition.new(:born, :crashed)) do
        bootstrap.send_exited_message(instance, EXIT_REASON_CRASHED)
      end

      resource_manager = bootstrap.resource_manager
      unless resource_manager.could_reserve?(attributes["limits"]["mem"], attributes["limits"]["disk"])
        constrained_resource = resource_manager.get_constrained_resource(attributes["limits"]["mem"],
                                                                         attributes["limits"]["disk"])
        logger.error "instance.start.insufficient-resource",
                     :app => instance.attributes["application_id"],
                     :instance => instance.attributes["instance_index"],
                     :constrained_resource => constrained_resource

        instance.exit_description = "Not enough #{constrained_resource} resource available."
        instance.state = Instance::State::CRASHED
        return nil
      end

      instance.setup

      instance.on(Instance::Transition.new(:starting, :crashed)) do
        bootstrap.send_exited_message(instance, EXIT_REASON_CRASHED)
      end

      instance.on(Instance::Transition.new(:starting, :running)) do
        # Notify others immediately
        bootstrap.send_heartbeat()

        # Register with router
        bootstrap.router_client.register_instance(instance)
      end

      instance.on(Instance::Transition.new(:running, :crashed)) do
        bootstrap.router_client.unregister_instance(instance)
        bootstrap.send_exited_message(instance, EXIT_REASON_CRASHED)
      end

      instance.on(Instance::Transition.new(:running, :stopping)) do
        bootstrap.router_client.unregister_instance(instance)
        bootstrap.send_instance_stop_message(instance)
      end

      instance.on(Instance::Transition.new(:starting, :stopping)) do
        bootstrap.send_instance_stop_message(instance)
      end

      instance.on(Instance::Transition.new(:starting, :running)) do
        bootstrap.snapshot.save
      end

      instance.on(Instance::Transition.new(:running, :stopping)) do
        bootstrap.snapshot.save
      end

      instance.on(Instance::Transition.new(:running, :crashed)) do
        bootstrap.snapshot.save
      end

      instance.on(Instance::Transition.new(:stopping, :stopped)) do
        bootstrap.instance_registry.unregister(instance)
        EM.next_tick { instance.destroy }
      end

      bootstrap.instance_registry.register(instance)
      instance
    end

    private

    attr_reader :bootstrap

  end
end
