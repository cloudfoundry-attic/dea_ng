# coding: UTF-8

require "em/warden/client/connection"
require "steno"
require "steno/core_ext"

require "dea/promise"

module Dea
  class Task

    class BaseError < StandardError
    end

    class WardenError < BaseError
    end

    attr_reader :bootstrap

    def initialize(bootstrap)
      @bootstrap = bootstrap

      # Cache warden connections
      @warden_connections = {}
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
      connection = @warden_connections.delete(name)

      if connection
        connection.close_connection
      end
    end

    def promise_warden_connection(name)
      Promise.new do |p|
        connection = find_warden_connection(name)

        # Deliver cached connection if possible
        if connection && connection.connected?
          p.deliver(connection)
        else
          socket = bootstrap.config["warden_socket"]
          klass  = ::EM::Warden::Client::Connection

          begin
            connection = ::EM.connect_unix_domain(socket, klass)
          rescue => error
            p.fail(WardenError.new("Cannot connect to warden on #{socket}: #{error.message}"))
          end

          if connection
            connection.on(:connected) do
              cache_warden_connection(name, connection)

              p.deliver(connection)
            end

            connection.on(:disconnected) do
              p.fail(WardenError.new("Cannot connect to warden on #{socket}"))
            end
          end
        end
      end
    end

    def promise_warden_call(connection_name, request)
      Promise.new do |p|
        logger.debug2(request.inspect)
        connection = promise_warden_connection(connection_name).resolve
        connection.call(request) do |result|
          logger.debug2(result.inspect)

          error = nil

          begin
            response = result.get
          rescue => error
          end

          if error
            logger.warn "Request failed: #{request.inspect}"
            logger.log_exception(error)

            p.fail(error)
          else
            p.deliver(response)
          end
        end
      end
    end

    def promise_warden_call_with_retry(connection_name, request)
      Promise.new do |p|
        response = nil

        begin
          response = promise_warden_call(connection_name, request).resolve
        rescue ::EM::Warden::Client::ConnectionError => error
          logger.warn("Request failed: #{request.inspect}, retrying")
          logger.log_exception(error)
          retry
        end

        p.deliver(response)
      end
    end

  end
end
