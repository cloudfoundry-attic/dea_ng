# coding: UTF-8

require "dea/health_check/base"

module Dea
  module HealthCheck
    class PortOpen < ::Dea::HealthCheck::Base

      class ConnectionNotifier < ::EM::Connection

        attr_reader :deferrable

        def initialize(deferrable)
          super

          @connection_completed = false

          @deferrable = deferrable
        end

        def connection_completed
          @connection_completed = true

          deferrable.succeed
        end

        def unbind
          # ECONNREFUSED, ECONNRESET, etc.
          deferrable.mark_failure unless @connection_completed
        end
      end

      attr_reader :host
      attr_reader :port

      def initialize(host, port, retry_interval_secs = 0.5)
        super()

        @host  = host
        @port  = port
        @timer = nil
        @retry_interval_secs = retry_interval_secs

        yield self if block_given?

        ::EM.next_tick { attempt_connect }
      end

      def mark_failure
        @timer = ::EM::Timer.new(@retry_interval_secs) { attempt_connect }
      end

      private

      def attempt_connect
        @conn = ::EM.connect(host, port, ConnectionNotifier, self) unless done?
      end

      def cleanup
        @conn.close_connection

        if @timer
          @timer.cancel
          @timer = nil
        end
      end
    end
  end
end
