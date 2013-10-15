# coding: UTF-8

module Dea
  class StagingEnv
    attr_reader :message, :staging_task

    def initialize(message, staging_task)
      @message = message.start_message
      @staging_task = staging_task
    end

    def exported_system_environment_variables
      [
        ["BUILDPACK_CACHE", staging_task.staging_config["environment"]["BUILDPACK_CACHE"]],
        ["STAGING_TIMEOUT", staging_task.staging_timeout],
        ["MEMORY_LIMIT", "#{message.mem_limit}m"]
      ]
    end

    def vcap_application
      {}
    end
  end
end