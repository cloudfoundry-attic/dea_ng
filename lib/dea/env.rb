# coding: UTF-8

require "steno"
require "steno/core_ext"
require "yajl"
require "dea/starting/database_uri_generator"

module Dea
  class Env
    attr_reader :message_json, :instance

    def initialize(message_json, instance=nil)
      @message_json = message_json["start_message"] ? message_json["start_message"] : message_json
      @instance = instance
    end

    def system_environment_variables
      application = application_for_json
      services    = services_for_json

      env = []
      env << ["HOME", "$PWD/app"]
      env << ["PORT", "$VCAP_APP_PORT"]
      env << ["DATABASE_URL", DatabaseUriGenerator.new(message_json["services"]).database_uri] if message_json["services"].any?
      env << ["TMPDIR", "$PWD/tmp"]

      env << ["VCAP_APPLICATION",  Yajl::Encoder.encode(application)]
      env << ["VCAP_SERVICES",     Yajl::Encoder.encode(services)]
      env << ["MEMORY_LIMIT", "#{message_json['limits']['mem']}m"]

      if instance
        env << ["VCAP_APP_HOST",     application["host"]]
        env << ["VCAP_APP_PORT",     instance.instance_container_port]

        env << ["VCAP_CONSOLE_IP",   application["host"]]
        env << ["VCAP_CONSOLE_PORT", instance.instance_console_container_port]

        if message_json["debug"]
          env << ["VCAP_DEBUG_IP",     application["host"]]
          env << ["VCAP_DEBUG_PORT",   instance.instance_debug_container_port]
          # Set debug environment for buildpacks to process
          env << ["VCAP_DEBUG_MODE", message_json["debug"]]
        end
      end

      # Wrap variables above in single quotes (no interpolation)
      env = env.map do |(key, value)|
        [key, %{'%s'} % value.to_s]
      end

      env
    end

    def user_environment_variables
      translate_env(message_json["env"])
    end

    def all_envs_with_user_last
      system_environment_variables + user_environment_variables
    end

    private

    # The format used by VCAP_SERVICES
    def services_for_json
      whitelist = %W[name label tags plan plan_option credentials]

      services_hash = Hash.new { |h, k| h[k] = [] }

      message_json["services"].each do |service|
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
      # TODO(kowshik): Eliminate application_users as it is deprecated.
      hash = { "application_users" => [] }

      if instance
        %W[instance_id instance_index].each do |key|
          hash[key] = instance.send(key)
        end
        hash["port"]                 = instance.instance_container_port

        started_at = Time.at(instance.state_starting_timestamp)

        hash["started_at"]           = started_at
        hash["started_at_timestamp"] = started_at.to_i

        hash["start"]           = hash["started_at"]
        hash["state_timestamp"] = hash["started_at_timestamp"]
      end

      hash["host"]                 = "0.0.0.0"

      hash["limits"]               = message_json["limits"]
      hash["application_version"]  = message_json["version"]
      hash["application_name"]     = message_json["name"]
      hash["application_uris"]     = message_json["uris"]

      # Translate keys for backwards compatibility
      hash["version"]         = hash["application_version"]
      hash["name"]            = hash["application_name"]
      hash["uris"]            = hash["application_uris"]
      hash["users"]           = hash["application_users"]

      hash
    end

    def translate_env(env)
      return [] unless env

      #TODO refactor this; duplicated in instance.rb:translate_attributes
      env = Hash[env.map do |e|
        pair = e.split("=", 2)
        pair[0] = pair[0].to_s
        pair[1] = pair[1].to_s
        pair
      end]

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
