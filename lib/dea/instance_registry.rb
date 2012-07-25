# coding: UTF-8

require "steno"
require "steno/core_ext"

module Dea
  class InstanceRegistry

    include Enumerable

    def initialize
      @instances = {}
      @instances_by_app_id = {}
    end

    def register(instance)
      logger.debug2("Registering instance #{instance.instance_id}")

      @instances[instance.instance_id] = instance

      app_id = instance.application_id
      @instances_by_app_id[app_id] ||= {}
      @instances_by_app_id[app_id][instance.instance_id] = instance

      nil
    end

    def unregister(instance)
      logger.debug2("Removing instance #{instance.instance_id}")

      @instances.delete(instance.instance_id)

      app_id = instance.application_id
      if @instances_by_app_id.has_key?(app_id)
        @instances_by_app_id[app_id].delete(instance.instance_id)

        if @instances_by_app_id[app_id].empty?
          @instances_by_app_id.delete(app_id)
        end
      end

      nil
    end

    def instances_for_application(app_id)
      @instances_by_app_id[app_id] || {}
    end

    def lookup_instance(instance_id)
      @instances[instance_id]
    end

    def each
      @instances.each { |_, instance| yield instance }
    end

    def empty?
      @instances.empty?
    end

    private

    def logger
      @logger ||= self.class.logger
    end
  end
end
