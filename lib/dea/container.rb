module Dea
  class Container
    class ConnectionError < StandardError; end

    attr_reader :handle, :socket_path

    def initialize(handle, socket_path)
      @handle = handle
      @socket_path = socket_path
      @warden_connections = {}
    end

    def info
      request = ::Warden::Protocol::InfoRequest.new
      request.handle = @handle

      Promise.new do |p|
        connection(:info).call(request) do |result|
          begin
            response = result.get
          rescue => error
            p.fail(error)
          else
            p.deliver(response)
          end
        end
      end.resolve
    end

    private

    def connection(name)
      promise_warden_connection(name).resolve
    end

    def promise_warden_connection(name)
      Promise.new do |p|
        connection = find_warden_connection(name)

        # Deliver cached connection if possible
        if connection && connection.connected?
          p.deliver(connection)
        else
          socket = @socket_path
          klass  = ::EM::Warden::Client::Connection

          begin
            connection = ::EM.connect_unix_domain(socket, klass)
          rescue => error
            p.fail(ConnectionError.new("Cannot connect to warden on #{socket}: #{error.message}"))
          end

          if connection
            connection.on(:connected) do
              cache_warden_connection(name, connection)

              p.deliver(connection)
            end

            connection.on(:disconnected) do
              p.fail(ConnectionError.new("Cannot connect to warden on #{socket}"))
            end
          end
        end
      end
    end

    def find_warden_connection(name)
      @warden_connections[name]
    end

    def cache_warden_connection(name, connection)
      @warden_connections[name] = connection
    end

    def close_warden_connections
      @warden_connections.keys.each do |name|
        close_warden_connection(name)
      end
    end

    def close_warden_connection(name)
      if connection = @warden_connections.delete(name)
        connection.close_connection
      end
    end
  end
end