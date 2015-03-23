# coding: UTF-8

module Dea
  module Staging
    class Env
      attr_reader :message, :staging_task

      def initialize(message, staging_task)
        @message = message
        @staging_task = staging_task
      end

      def system_environment_variables
        [
          ["STAGING_TIMEOUT", staging_task.staging_timeout],
          ["MEMORY_LIMIT", "#{message.mem_limit}m"]
        ]
      end

      def vcap_application
        {}
      end
    end
  end
end
