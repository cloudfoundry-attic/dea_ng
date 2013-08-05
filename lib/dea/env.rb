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

    def exported_system_environment_variables
      env = []
      env << ["HOME", "$PWD/app"]
      env << ["DATABASE_URL", DatabaseUriGenerator.new(message_json["services"]).database_uri] if message_json["services"].any?
      env << ["TMPDIR", "$PWD/tmp"]

      env << ["VCAP_APPLICATION",  Yajl::Encoder.encode(vcap_application)]
      env << ["VCAP_SERVICES",     Yajl::Encoder.encode(vcap_services)]
      env << ["MEMORY_LIMIT", "#{message_json['limits']['mem']}m"]

      if instance
        env << ["VCAP_APP_HOST",     vcap_application["host"]]
        env << ["VCAP_APP_PORT",     instance.instance_container_port]

        env << ["VCAP_CONSOLE_IP",   vcap_application["host"]]
        env << ["VCAP_CONSOLE_PORT", instance.instance_console_container_port]

        if message_json["debug"]
          env << ["VCAP_DEBUG_IP",     vcap_application["host"]]
          env << ["VCAP_DEBUG_PORT",   instance.instance_debug_container_port]
          # Set debug environment for buildpacks to process
          env << ["VCAP_DEBUG_MODE", message_json["debug"]]
        end

        env << ["PORT", "$VCAP_APP_PORT"]
      end

      to_export(env)
    end

    def exported_user_environment_variables
      to_export(translate_env(message_json["env"]))
    end

    def exported_environment_variables
      exported_system_environment_variables + exported_user_environment_variables
    end

    private

    def vcap_services
      @vcap_services ||=
        begin
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
    end

    def vcap_application
      @vcap_application ||=
        begin
          # TODO(kowshik): Eliminate application_users as it is deprecated.
          hash = { "application_users" => [] }

          if instance
            %W[instance_id instance_index].each do |key|
              hash[key] = instance.send(key)
            end
            hash["port"] = instance.instance_container_port

            started_at = Time.at(instance.state_starting_timestamp)

            hash["started_at"] = started_at
            hash["started_at_timestamp"] = started_at.to_i

            hash["start"] = hash["started_at"]
            hash["state_timestamp"] = hash["started_at_timestamp"]
          end

          hash["host"] = "0.0.0.0"

          hash["limits"] = message_json["limits"]
          hash["application_version"] = message_json["version"]
          hash["application_name"] = message_json["name"]
          hash["application_uris"] = message_json["uris"]

          # Translate keys for backwards compatibility
          hash["version"] = hash["application_version"]
          hash["name"] = hash["application_name"]
          hash["uris"] = hash["application_uris"]
          hash["users"] = hash["application_users"]

          hash
        end
    end

    def translate_env(env)
      # TODO: duplicated in instance.rb#translate_attributes
      env ? env.map { |e| e.split("=", 2) } : []
    end

    def to_export(envs)
      envs.map do |(key, value)|
        %Q{export %s="%s";\n} % [key, value.to_s.gsub('"', '\"')]
      end.join
    end
  end
end
