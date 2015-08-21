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
    class BaseError < StandardError;
    end
    class NotImplemented < StandardError;
    end

    BIND_MOUNT_MODE_MAP = {
      "ro" => ::Warden::Protocol::CreateRequest::BindMount::Mode::RO,
      "rw" => ::Warden::Protocol::CreateRequest::BindMount::Mode::RW,
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

    def promise_stop(kill_flag = false)
      Promise.new do |p|
        begin
          if container.handle
            request = ::Warden::Protocol::StopRequest.new(handle: container.handle, kill: kill_flag)
            container.call(:stop, request)
          end

          p.deliver
        rescue Exception => error
          handles = container.list.handles
          if handles != nil && handles.include?(container.handle)
            logger.error("task.stop.failed", error: error, backtrace: error.backtrace)
            p.fail(error)
          else
            p.deliver # if the container is no longer listed, the stop has succeeded
          end
        end
      end
    end

    def promise_destroy
      Promise.new do |promise|
        if container.handle.nil?
          logger.error("task.destroy.invalid")
        else
          request = ::Warden::Protocol::DestroyRequest.new(handle: container.handle)

          begin
            container.call_with_retry(:app, request)
          rescue ::EM::Warden::Client::Error => error
            logger.warn("task.destroy.failed", error: error, backtrace: error.backtrace)
          end

          container.handle = nil
        end

        promise.deliver
      end
    end

    def destroy(&callback)
      promise = Promise.new do
        logger.info("task.destroying")
        promise_destroy.resolve
        promise.deliver
      end

      resolve_and_log(promise, "task.destroy") do |error, _|
        callback.call(error) unless callback.nil?
        @container.close_all_connections if @container
      end
    end

    def resolve_and_log(p, name)
      Promise.resolve(p) do |error, result|
        begin
          yield(error, result)
        rescue => e
          error = e
        end

        if error
          logger.warn("#{name}.failed with error #{error}", duration: p.elapsed_time, error: error, backtrace: error.backtrace)

          p.fail(error)
        else
          logger.warn("#{name}.completed", duration: p.elapsed_time)

          p.deliver
        end
      end
    end

    def copy_out_request(source_path, destination_path)
      FileUtils.mkdir_p(destination_path)

      request = ::Warden::Protocol::CopyOutRequest.new(handle: container.handle,
                                                       src_path: source_path,
                                                       dst_path: destination_path,
                                                       owner: Process.uid.to_s)

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
