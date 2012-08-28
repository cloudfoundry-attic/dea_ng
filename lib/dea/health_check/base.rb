# coding: UTF-8

require "eventmachine"

module Dea
  module HealthCheck

    class Base

      include ::EM::Deferrable

      def initialize
        setup_callbacks
      end

      private

      def setup_callbacks
        [:callback, :errback].each do |method|
          send(method) { cleanup }
        end
      end

      # Can potentially be called more than once, so make it idempotent.
      def cleanup
      end
    end

  end
end
