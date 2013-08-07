# coding: UTF-8

module Dea
  class StagingEnv
    attr_reader :message_json, :staging_task

    def initialize(message_json, staging_task)
      @message_json = message_json["start_message"]
      @staging_task = staging_task
    end

    def exported_system_environment_variables
      [
        ["PLATFORM_CONFIG", staging_task.workspace.platform_config_path],
        ["BUILDPACK_CACHE", staging_task.staging_config["environment"]["BUILDPACK_CACHE"]],
        ["STAGING_TIMEOUT", staging_task.staging_timeout],
        ["MEMORY_LIMIT", "#{message_json["limits"]["mem"]}m"]
      ]
    end

    def vcap_application
      {}
    end
  end
end