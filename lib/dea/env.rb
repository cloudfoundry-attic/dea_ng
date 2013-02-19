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

    # The format used by VMC_SERVICES
    def legacy_services_for_json
      whitelisted_keys = %W(name type vendor version)
      translated_keys = {
        "plan"        => "tier",
        "credentials" => "options",
      }

      instance.services.map do |service|
        legacy_service = {}

        whitelisted_keys.each do |k|
          legacy_service[k] = service[k] if service[k]
        end

        translated_keys.each do |current_key, legacy_key|
          legacy_service[legacy_key] = service[current_key]
        end

        legacy_service
      end
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

    # Legacy format. Currently needed to pass BVTs.
    def legacy_env
      application = application_for_json
      services    = legacy_services_for_json

      warning = "All VMC_* environment variables are deprecated, please use "
      warning += "VCAP_* versions."

      lenv = []
      lenv << ["VMC_WARNING_WARNING", warning]
      lenv << ["VMC_SERVICES",     Yajl::Encoder.encode(services)]
      lenv << ["VMC_APP_INSTANCE", Yajl::Encoder.encode(application)]
      lenv << ["VMC_APP_NAME",     application["name"]]
      lenv << ["VMC_APP_ID",       application["instance_id"]]
      lenv << ["VMC_APP_VERSION",  application["version"]]
      lenv << ["VMC_APP_HOST",     application["host"]]
      lenv << ["VMC_APP_PORT",     application["port"]]

      instance.services.each do |service|
        creds  = service["credentials"] || {}
        host   = creds["hostname"] || creds["host"]
        port   = creds["port"]
        vendor = service["vendor"].upcase

        next if host.nil? || port.nil?

        lenv << ["VMC_#{vendor}", "#{host}:#{port}"]
      end

      lenv
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
      end

      # Remove this once BVTs are updated/killed.
      env.concat(legacy_env)

      # Wrap variables above in single quotes (no interpolation)
      env = env.map do |(key, value)|
        [key, %{'%s'} % value.to_s]
      end

      # Prepare user-specified environment
      instance_environment = instance.environment.map do |(key, value)|
        # Wrap value in double quotes if it isn't already (allows interpolation)
        unless value =~ /^['"]/
          value = %{"%s"} % value
        end

        [key, value]
      end

      # Include user-specified environment
      env.concat(instance_environment)

      env
    end
  end
end
