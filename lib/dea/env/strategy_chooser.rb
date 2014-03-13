require "dea/staging/staging_message"
require "dea/staging/env"
require "dea/starting/env"

module Dea
  class Env
    class StrategyChooser
      def initialize(message, task)
        @message = message
        @task = task
      end

      def strategy
        if @message.is_a? StagingMessage
          Staging::Env.new(@message, @task)
        else
          Starting::Env.new(@message, @task)
        end
      end
    end
  end
end
