# coding: UTF-8

require "steno/core_ext"
require "yajl"

require "dea/health_check/base"

module Dea
  module HealthCheck
    class StateFileReady < ::Dea::HealthCheck::Base
      attr_reader :path

      def initialize(path, retry_interval_secs = 0.5)
        super()
        @path  = path

        yield self if block_given?

        @timer = ::EM::PeriodicTimer.new(retry_interval_secs) do
          check_state_file
        end

        check_state_file
      end

      private

      def check_state_file
        return unless File.exists?(path)

        state = Yajl::Parser.parse(File.read(path))
        if state && state["state"] == "RUNNING"
          succeed
        end

      rescue => e
        logger.error("Failed parsing state file: #{e}")
        logger.log_exception(e)
        # Ignore errors, health check will time out if errors persist.
      end

      def cleanup
        if @timer
          @timer.cancel
          @timer = nil
        end
      end

      def logger
        self.class.logger
      end
    end
  end
end
