# coding: UTF-8

require "steno"
require "steno/core_ext"
require "yajl"

module Dea
  class Env
    attr_reader :instance

    def initialize(instance)
      @instance = instance
    end

    # The format used by VCAP_SERVICES
    def services_for_json
      whitelist = %W(
        name
        label
        tags
        plan
        plan_option
        credentials
      )

      services_hash = Hash.new { |h, k| h[k] = [] }

      instance.services.each do |service|
        service_hash = {}
        whitelist.each do |key|
          service_hash[key] = service[key] if service[key]
        end

        services_hash[service["label"]] << service_hash
      end

      services_hash
    end

    # The format used by VCAP_APPLICATION
    def application_for_json
      keys = %W(
        instance_id
        instance_index

        application_version
        application_name
        application_uris
        application_users

        runtime_name
      )

      hash = {}

      keys.each do |key|
        hash[key] = instance.send(key)
      end

      hash["started_at"]           = instance.started_at
      hash["started_at_timestamp"] = instance.started_at.to_i
      hash["host"]                 = "0.0.0.0"
      hash["port"]                 = instance.instance_container_port
      hash["limits"]               = instance.limits

      # Translate keys for backwards compatibility
      hash["version"]         = hash["application_version"]
      hash["name"]            = hash["application_name"]
      hash["uris"]            = hash["application_uris"]
      hash["users"]           = hash["application_users"]

      hash["runtime"]         = hash["runtime_name"]
      hash["start"]           = hash["started_at"]
      hash["state_timestamp"] = hash["started_at_timestamp"]

      hash
    end

    def env
      application = application_for_json
      services    = services_for_json

      env = []
      env << ["VCAP_APPLICATION",  Yajl::Encoder.encode(application)]
      env << ["VCAP_SERVICES",     Yajl::Encoder.encode(services)]

      env << ["VCAP_APP_HOST",     application["host"]]
      env << ["VCAP_APP_PORT",     instance.instance_container_port]
      env << ["VCAP_DEBUG_IP",     application["host"]]
      env << ["VCAP_DEBUG_PORT",   instance.instance_debug_container_port]
      env << ["VCAP_CONSOLE_IP",   application["host"]]
      env << ["VCAP_CONSOLE_PORT", instance.instance_console_container_port]

      # Include debug environment for runtime
      if instance.debug
        env.concat(instance.runtime.debug_environment(instance.debug).to_a)
      end

      # Include environment for runtime
      env.concat(instance.runtime.environment.to_a)

      # Include user-specified environment
      env.concat(instance.environment.to_a)

      env
    end
  end
end
