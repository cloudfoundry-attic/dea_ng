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

    def initialize(name, socket, base_dir)
      @name = name
      @socket = socket
      @warden_connection = nil
      @base_dir = base_dir
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
      Promise.new do |p|
        logger.debug2(request.inspect)
        @warden_connection.call(request) do |result|
          logger.debug2(result.inspect)
          error = nil

          begin
            response = result.get
          rescue => error
            logger.warn "Request failed: #{request.inspect} file touched: #{file_touch_output} VMstat out: #{vmstat_snapshot_output}"
            logger.log_exception(error)

            p.fail(error)
          else
            p.deliver(response)
          end
        end
      end
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

    def logger
      tags = { "connection_name" => name }
      @logger ||= self.class.logger.tag(tags)
    end

    private

    def file_touch_output
      FileUtils.touch(File.join(@base_dir, "tmp", "test_promise_warden_call")) && "passed"
    rescue
      "failed"
    end

    def vmstat_snapshot_output
      Vmstat.snapshot.inspect
    rescue
      "Unable to get Vmstat.snapshot"
    end
  end
end