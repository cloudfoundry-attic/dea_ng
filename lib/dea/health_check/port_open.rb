require "eventmachine"

module Dea
  module HealthCheck
    class PortOpen

      class ConnectionNotifier < ::EM::Connection

        attr_reader :deferrable

        def initialize(deferrable)
          super

          @deferrable = deferrable
        end

        def connection_completed
          deferrable.succeed
        end

        def unbind
          # ECONNREFUSED, ECONNRESET, etc.
          deferrable.mark_failure if error?
        end
      end

      include EM::Deferrable

      attr_reader :host
      attr_reader :port

      def initialize(host, port, retry_interval_secs = 0.5)
        @host  = host
        @port  = port
        @timer = nil
        @retry_interval_secs = retry_interval_secs

        setup_callbacks

        yield self if block_given?

        ::EM.next_tick { attempt_connect }
      end

      def mark_failure
        @timer = ::EM::Timer.new(@retry_interval_secs) { attempt_connect }
      end

      private

      def setup_callbacks
        [:callback, :errback].each do |method|
          send(method) { cleanup }
        end
      end

      def attempt_connect
        @conn = ::EM.connect(host, port, ConnectionNotifier, self)
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
