# coding: UTF-8

require "em/warden/client/connection"
require "steno"
require "steno/core_ext"
require "dea/promise"
require "vmstat"
require "dea/container/container"

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
      @container ||= Dea::Container.new(config["warden_socket"], config["base_dir"])
    end

    def paths_to_bind
      []
    end

    def promise_create_container
      Promise.new do |p|
        bind_mounts = paths_to_bind.map do |path|
          bind_mount = ::Warden::Protocol::CreateRequest::BindMount.new
          bind_mount.src_path = path
          bind_mount.dst_path = path
          bind_mount.mode = ::Warden::Protocol::CreateRequest::BindMount::Mode::RO
          bind_mount
        end

        # extra mounts (currently just used for the buildpack cache)
        config["bind_mounts"].each do |bm|
          bind_mount = ::Warden::Protocol::CreateRequest::BindMount.new

          bind_mount.src_path = bm["src_path"]
          bind_mount.dst_path = bm["dst_path"] || bm["src_path"]

          mode = bm["mode"] || "ro"
          bind_mount.mode = BIND_MOUNT_MODE_MAP[mode]

          bind_mounts << bind_mount
        end

        create_request = ::Warden::Protocol::CreateRequest.new
        create_request.bind_mounts = bind_mounts

        response = container.call(:app, create_request)

        @attributes["warden_handle"] = response.handle
        container.handle = @attributes["warden_handle"]
        logger.user_data[:warden_handle] = response.handle

        p.deliver
      end
    end

    def promise_limit_disk
      Promise.new do |p|
        request = ::Warden::Protocol::LimitDiskRequest.new
        request.handle = container_handle
        request.byte = disk_limit_in_bytes
        container.call(:app, request)
        p.deliver
      end
    end

    def promise_limit_memory
      Promise.new do |p|
        request = ::Warden::Protocol::LimitMemoryRequest.new
        request.handle = container_handle
        request.limit_in_bytes = memory_limit_in_bytes
        container.call(:app, request)
        p.deliver
      end
    end

    def container_handle
      @attributes["warden_handle"]
    end

    def promise_stop
      Promise.new do |p|
        request = ::Warden::Protocol::StopRequest.new
        request.handle = container_handle
        container.call(:stop, request)

        p.deliver
      end
    end

    def promise_destroy
      Promise.new do |promise|
        request = ::Warden::Protocol::DestroyRequest.new
        request.handle = container_handle

        begin
          container.call_with_retry(:app, request)
        rescue ::EM::Warden::Client::Error => error
          logger.warn("Error destroying container: #{error.message}")
        end

        # Remove container handle from attributes now that it can no longer be used
        attributes.delete("warden_handle")

        promise.deliver
      end
    end

    def destroy(&callback)
      promise = Promise.new do
        logger.info("Destroying instance")

        promise_destroy.resolve

        promise.deliver
      end

      resolve(promise, "destroy instance") do |error, _|
        callback.call(error) unless callback.nil?
      end
    end

    # Resolve a promise making sure that only one runs at a time.
    def resolve(p, name)
      if @busy
        logger.warn("Ignored: #{name}")
        return
      else
        @busy = true

        Promise.resolve(p) do |error, result|
          begin
            took = "took %.3f" % p.elapsed_time

            if error
              logger.warn("Failed: #{name} (#{took})")
              logger.log_exception(error)
            else
              logger.info("Delivered: #{name} (#{took})")
            end

            yield(error, result)
          ensure
            @busy = false
          end
        end
      end
    end

    def copy_out_request(source_path, destination_path)
      FileUtils.mkdir_p(destination_path)

      request = ::Warden::Protocol::CopyOutRequest.new
      request.handle = attributes["warden_handle"]
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
