require "em/warden/client"
require "dea/container/connection"

module Dea
  class Container
    class ConnectionError < StandardError; end

    attr_reader :socket_path
    attr_accessor :handle

    def initialize(socket_path, base_dir)
      @socket_path = socket_path
      @connections = {}
      @base_dir = base_dir
    end

    def info
      request = ::Warden::Protocol::InfoRequest.new
      request.handle = @handle
      client.call(request)
    end

    def find_connection(name)
      @connections[name]
    end

    def cache_connection(name, connection)
      @connections[name] = connection
    end

    def close_all_connections
      @connections.keys.each do |name|
        close_connection(name)
      end
    end

    def close_connection(name)
      if connection = @connections.delete(name)
        connection.close
      end
    end

    def get_connection(name)
      connection = find_connection(name)

      # Deliver cached connection if possible
      if connection && connection.connected?
        return connection
      else
        connection = Connection.new(name, socket_path, @base_dir)
        connection.promise_create.resolve
        cache_connection(name, connection) if connection
        return connection
      end
    end

    def call(name, request)
      connection = get_connection(name)
      connection.promise_call(request).resolve
    end

    private

    def client
      @client ||=
        EventMachine::Warden::FiberAwareClient.new(@socket_path).tap(&:connect)
    end
  end
end