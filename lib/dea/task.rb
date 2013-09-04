# coding: UTF-8

require "em/warden/client/connection"
require "steno"
require "steno/core_ext"
require "dea/promise"
require "vmstat"
require "container/container"
require "container/warden_client_provider"

module Dea
  class Task
    class BaseError < StandardError; end
    class NotImplemented < StandardError; end

    BIND_MOUNT_MODE_MAP = {
      "ro" =>  ::Warden::Protocol::CreateRequest::BindMount::Mode::RO,
      "rw" =>  ::Warden::Protocol::CreateRequest::BindMount::Mode::RW,
    }

    attr_reader :config
    attr_reader :logger

    def initialize(config, custom_logger=nil)
      @config = config
      @logger = custom_logger || self.class.logger.tag({})
    end

    def start(&blk)
      raise NotImplemented
    end

    def container
      @container ||= begin
        connection_provider = WardenClientProvider.new(config["warden_socket"])
        Container.new(connection_provider)
      end
    end

    def paths_to_bind
      []
    end

    def promise_stop
      Promise.new do |p|
        request = ::Warden::Protocol::StopRequest.new
        request.handle = container.handle
        container.call(:stop, request)

        p.deliver
      end
    end

    def promise_destroy
      Promise.new do |promise|
        request = ::Warden::Protocol::DestroyRequest.new
        request.handle = container.handle

        begin
          container.call_with_retry(:app, request)
        rescue ::EM::Warden::Client::Error => error
          logger.warn("Error destroying container: #{error.message}")
        end

        container.handle = nil
        promise.deliver
      end
    end

    def destroy(&callback)
      promise = Promise.new do
        logger.info("Destroying instance")

        promise_destroy.resolve

        promise.deliver
      end

      resolve_and_log(promise, "destroy instance") do |error, _|
        callback.call(error) unless callback.nil?
      end
    end

    def resolve_and_log(p, name)
      Promise.resolve(p) do |error, result|
        took = "took %.3f" % p.elapsed_time

        if error
          logger.warn("Failed: #{name} (#{took})")
          logger.log_exception(error)
        else
          logger.info("Delivered: #{name} (#{took})")
        end

        yield(error, result)
      end
    end

    def copy_out_request(source_path, destination_path)
      FileUtils.mkdir_p(destination_path)

      request = ::Warden::Protocol::CopyOutRequest.new
      request.handle = container.handle
      request.src_path = source_path
      request.dst_path = destination_path
      request.owner = Process.uid.to_s

      begin
        container.call_with_retry(:app, request)
      rescue ::EM::Warden::Client::Error => error
        logger.warn("Error copying files out of container: #{error.message}")
      end
    end

    def consuming_memory?
      true
    end

    def consuming_disk?
      true
    end
  end
end
