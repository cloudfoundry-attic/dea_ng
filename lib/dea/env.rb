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
      keys = %W[
        instance_id
        instance_index

        application_version
        application_name
        application_uris
      ]

      # TODO(kowshik): Eliminate application_users as it is deprecated.
      hash = { "application_users" => [] }

      keys.each do |key|
        hash[key] = instance.send(key)
      end

      started_at = Time.at(instance.state_starting_timestamp)

      hash["started_at"]           = started_at
      hash["started_at_timestamp"] = started_at.to_i
      hash["host"]                 = "0.0.0.0"
      hash["port"]                 = instance.instance_container_port
      hash["limits"]               = instance.limits

      # Translate keys for backwards compatibility
      hash["version"]         = hash["application_version"]
      hash["name"]            = hash["application_name"]
      hash["uris"]            = hash["application_uris"]
      hash["users"]           = hash["application_users"]

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

      env << ["VCAP_CONSOLE_IP",   application["host"]]
      env << ["VCAP_CONSOLE_PORT", instance.instance_console_container_port]

      if instance.debug
        env << ["VCAP_DEBUG_IP",     application["host"]]
        env << ["VCAP_DEBUG_PORT",   instance.instance_debug_container_port]
        # Set debug environment for buildpacks to process
        env << ["VCAP_DEBUG_MODE", instance.debug]
      end

      # Wrap variables above in single quotes (no interpolation)
      env = env.map do |(key, value)|
        [key, %{'%s'} % value.to_s]
      end

      # Include user-specified environment
      env.concat(translate_env(instance.environment))

      env
    end

    def translate_env(env)
      return [] unless env
      env.map do |(key, value)|
        # Wrap value in double quotes if it isn't already (allows interpolation)
        unless value =~ /^['"]/
          value = %{"%s"} % value
        end

        [key, value]
      end
    end
  end
end
