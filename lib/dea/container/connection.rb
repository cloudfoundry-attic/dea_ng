require "em/warden/client/connection"
require "steno"
require "steno/core_ext"
require "dea/promise"
require "vmstat"

module Dea
  class Connection
    class ConnectionError < StandardError; end
    class WardenError < StandardError; end

    attr_reader :name, :socket

    def initialize(name, socket)
      @name = name
      @socket = socket
    end

    def close
    end

    def promise_run(script)
      # This calls promise_call with RunRequest
    end

    def promise_call(request)
    end

    def promise_call_with_retry(request)
    end

    def promise_create
      Promise.new do |p|
        begin
          connection = ::EM.connect_unix_domain(socket, ::EM::Warden::Client::Connection)
        rescue => error
          p.fail(WardenError.new("Cannot connect to warden on #{socket}: #{error.message}"))
        end

        if connection
          connection.on(:connected) do
            p.deliver(connection)
          end

          connection.on(:disconnected) do
            p.fail(WardenError.new("Cannot connect to warden on #{socket}"))
          end
        end
      end
    end
  end
end