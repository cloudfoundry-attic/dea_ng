require "em/warden/client"
require "dea/container/connection"

module Dea
  class Container
    class ConnectionError < StandardError; end

    attr_reader :socket_path
    attr_accessor :handle

    def initialize(socket_path)
      @socket_path = socket_path
      @warden_connections = {}
    end

    def info
      request = ::Warden::Protocol::InfoRequest.new
      request.handle = @handle
      client.call(request)
    end

    def find_connection(name)
      @warden_connections[name]
    end

    def cache_connection(name, connection)
      @warden_connections[name] = connection
    end

    def close_all_connections
      @warden_connections.keys.each do |name|
        close_connection(name)
      end
    end

    def close_connection(name)
      if connection = @warden_connections.delete(name)
        connection.close_connection
      end
    end

    def get_connection(name)
      connection = find_connection(name)

      # Deliver cached connection if possible
      if connection && connection.connected?
        return connection
      else
        connection = Connection.new(name, socket_path).promise_create.resolve
        cache_connection(name, connection) if connection
        return connection
      end
    end

    private

    def client
      @client ||=
        EventMachine::Warden::FiberAwareClient.new(@socket_path).tap(&:connect)
    end
  end
end