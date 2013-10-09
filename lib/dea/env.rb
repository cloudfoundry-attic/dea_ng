# coding: UTF-8

require "steno"
require "steno/core_ext"
require "yajl"

require "dea/staging/staging_task"
require "dea/staging/staging_env"

require "dea/starting/database_uri_generator"
require "dea/starting/running_env"

module Dea
  class Env
    WHITELIST_SERVICE_KEYS = %W[name label tags plan plan_option credentials].freeze

    attr_reader :strategy_env

    def initialize(message_json, instance_or_staging_task=nil)
      @strategy_env = if instance_or_staging_task.is_a? Dea::StagingTask
        StagingEnv.new(message_json, instance_or_staging_task)
      else
        RunningEnv.new(message_json, instance_or_staging_task)
      end
    end

    def message_json
      strategy_env.message_json
    end

    def exported_system_environment_variables
      env = [
        ["VCAP_APPLICATION",  Yajl::Encoder.encode(vcap_application)],
        ["VCAP_SERVICES",     Yajl::Encoder.encode(vcap_services)],
        ["MEMORY_LIMIT", "#{message_json['limits']['mem']}m"]
      ]
      env << ["DATABASE_URL", DatabaseUriGenerator.new(message_json["services"]).database_uri] if message_json["services"].any?

      to_export(env + strategy_env.exported_system_environment_variables)
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
          services_hash = Hash.new { |h, k| h[k] = [] }

          message_json["services"].each do |service|
            service_hash = {}
            WHITELIST_SERVICE_KEYS.each do |key|
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
          hash = strategy_env.vcap_application

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