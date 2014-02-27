# coding: UTF-8

module Dea
  class RunningEnv
    HOST = "0.0.0.0".freeze

    attr_reader :message, :instance

    def initialize(message, instance)
      @message = message
      @instance = instance
    end

    def exported_system_environment_variables
      env = [
        ["HOME", "$PWD/app"],
        ["TMPDIR", "$PWD/tmp"],
        ["VCAP_APP_HOST", HOST],
        ["VCAP_APP_PORT", instance.instance_container_port],
        ["PORT", instance.instance_container_port]
      ]
      env
    end

    def vcap_application
      hash = {}

      hash["instance_id"] = instance.attributes["instance_id"]
      hash["instance_index"] = message.index

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