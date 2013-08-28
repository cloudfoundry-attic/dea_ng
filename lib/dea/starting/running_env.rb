# coding: UTF-8

module Dea
  class RunningEnv
    HOST = "0.0.0.0".freeze
    WHITELIST_APP_KEYS = %W[instance_id instance_index].map(&:freeze).freeze

    attr_reader :message_json, :instance

    def initialize(message_json, instance)
      @message_json = message_json
      @instance = instance
    end

    def exported_system_environment_variables
      env = [
        ["HOME", "$PWD/app"],
        ["TMPDIR", "$PWD/tmp"],
        ["VCAP_APP_HOST", HOST],
        ["VCAP_APP_PORT", instance.instance_container_port],
      ]

      env << ["PORT", "$VCAP_APP_PORT"]

      env
    end

    def vcap_application
      hash = {}

      WHITELIST_APP_KEYS.each do |key|
        hash[key] = instance.send(key)
      end

      hash["host"] = HOST
      hash["port"] = instance.instance_container_port

      started_at = Time.at(instance.state_starting_timestamp)

      hash["started_at"] = started_at
      hash["started_at_timestamp"] = started_at.to_i

      hash["start"] = hash["started_at"]
      hash["state_timestamp"] = hash["started_at_timestamp"]

      hash
    end
  end
end