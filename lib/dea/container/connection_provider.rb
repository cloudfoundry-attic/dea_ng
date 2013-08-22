require "dea/container/connection"
module Dea
  class ConnectionProvider
    attr_reader :socket_path

    def initialize(socket_path)
      @socket_path = socket_path
      @connections = {}
    end

    def get(name)
      connection = @connections[name]

      return connection if connection && connection.connected?

      new_connection = Connection.new(name, @socket_path)
      new_connection.promise_create.resolve
      @connections[name] = new_connection
      new_connection
    end

    def close_all
      @connections.values.each(&:close)
    end
  end
end