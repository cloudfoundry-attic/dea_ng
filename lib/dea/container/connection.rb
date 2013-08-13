require "em/warden/client/connection"
require "steno"
require "steno/core_ext"
require "dea/promise"
require "vmstat"

module Dea
  class Connection
    class ConnectionError < StandardError; end
    class WardenError < StandardError; end

    attr_reader :name, :socket, :warden_connection

    def initialize(name, socket)
      @name = name
      @socket = socket
      @warden_connection = nil
    end

    def connected?
      @warden_connection.connected?
    end

    def close
      @warden_connection.close_connection
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
          @warden_connection = ::EM.connect_unix_domain(socket, ::EM::Warden::Client::Connection)
        rescue => error
          p.fail(WardenError.new("Cannot connect to warden on #{socket}: #{error.message}"))
        end

        if @warden_connection
          @warden_connection.on(:connected) do
            p.deliver
          end

          @warden_connection.on(:disconnected) do
            p.fail(WardenError.new("Cannot connect to warden on #{socket}"))
          end
        end
      end
    end
  end
end