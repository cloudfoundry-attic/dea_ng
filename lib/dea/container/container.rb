require "em/warden/client"
require "dea/container/connection"
require "dea"

module Dea
  class Container
    class ConnectionError < StandardError; end
    class BaseError < StandardError; end
    class WardenError < BaseError; end

    BIND_MOUNT_MODE_MAP = {
      "ro" => ::Warden::Protocol::CreateRequest::BindMount::Mode::RO,
      "rw" => ::Warden::Protocol::CreateRequest::BindMount::Mode::RW,
    }

    attr_reader :socket_path, :path, :host_ip, :network_ports
    attr_accessor :handle

    def initialize(connection_provider)
      @connection_provider = connection_provider
      @path = nil
      @network_ports = {}
    end

    #API: GETSTATE (returns the warden's state file)
    def update_path_and_ip
      raise ArgumentError, "container handle must not be nil" unless @handle

      request = ::Warden::Protocol::InfoRequest.new(:handle => @handle)
      response = call(:info, request)

      raise RuntimeError, "container path is not available" unless response.container_path
      @path = response.container_path
      @host_ip = response.host_ip

      response
    end

    #API: within CREATE
    def get_new_warden_net_in
      request = ::Warden::Protocol::NetInRequest.new
      request.handle = handle
      call(:app, request)
    end

    #API: within DESTROY
    # what do we do with link requests
    def call_with_retry(name, request)
      count = 0
      response = nil

      begin
        response = call(name, request)
      rescue ::EM::Warden::Client::ConnectionError => error
        count += 1
        logger.warn("Request failed: #{request.inspect}, retrying ##{count}.")
        logger.log_exception(error)
        retry
      end

      if count > 0
        logger.debug("Request succeeded after #{count} retries: #{request.inspect}")
      end
      response
    end

    #API: RUNSCRIPT
    def run_script(name, script, privileged=false)
      request = ::Warden::Protocol::RunRequest.new
      request.handle = handle
      request.script = script
      request.privileged = privileged

      response = call(name, request)
      if response.exit_status > 0
        data = {
        :script      => script,
        :exit_status => response.exit_status,
        :stdout      => response.stdout,
        :stderr      => response.stderr,
        }
        logger.warn("%s exited with status %d" % [script.inspect, response.exit_status], data)
        raise WardenError.new("Script exited with status #{response.exit_status}")
      else
        response
      end
    end

    #API: SPAWN
    def spawn(script, file_descriptor_limit, nproc_limit)
      request = ::Warden::Protocol::SpawnRequest.new
      request.rlimits = ::Warden::Protocol::ResourceLimits.new
      request.handle = handle
      request.rlimits.nproc = nproc_limit
      request.rlimits.nofile = file_descriptor_limit
      request.script = script
      response = call(:app, request)
      response
    end

    #API: DESTROY
    def destroy!
      Dea.with_em do
        request = ::Warden::Protocol::DestroyRequest.new
        request.handle = handle

        begin
          call_with_retry(:app, request)
        rescue ::EM::Warden::Client::Error => error
          logger.warn("Error destroying container: #{error.message}")
        end
        self.handle = nil
      end
    end

    def create_container(bind_mounts, disk_limit_in_bytes, memory_limit_in_bytes, network)
      Dea.with_em do
        new_container_with_bind_mounts(bind_mounts)
        limit_disk(disk_limit_in_bytes)
        limit_memory(memory_limit_in_bytes)
        setup_network if network
      end
    end

    def new_container_with_bind_mounts(bind_mounts)
      Dea.with_em do
        create_request = ::Warden::Protocol::CreateRequest.new
        create_request.bind_mounts = bind_mounts.map do |bm|

          bind_mount = ::Warden::Protocol::CreateRequest::BindMount.new
          bind_mount.src_path = bm["src_path"]
          bind_mount.dst_path = bm["dst_path"] || bm["src_path"]

          mode = bm["mode"] || "ro"
          bind_mount.mode = BIND_MOUNT_MODE_MAP[mode]
          bind_mount
        end

        response = call(:app, create_request)
        self.handle = response.handle
      end
    end

    # HELPER for DESTROY
    def close_all_connections
      @connection_provider.close_all
    end

    def setup_network
      request = ::Warden::Protocol::NetInRequest.new(handle: handle)
      response = call(:app, request)

      @network_ports["host_port"] = response.host_port
      @network_ports["container_port"] = response.container_port
    end

    # HELPER
    def info
      request = ::Warden::Protocol::InfoRequest.new
      request.handle = @handle
      client.call(request)
    end

    # HELPER
    def call(name, request)
      connection = @connection_provider.get(name)
      connection.promise_call(request).resolve
    end

    def limit_disk(bytes)
      request = ::Warden::Protocol::LimitDiskRequest.new(handle: self.handle, byte: bytes)
      call(:app, request)
    end

    def limit_memory(bytes)
      request = ::Warden::Protocol::LimitMemoryRequest.new(handle: self.handle, limit_in_bytes: bytes)
      call(:app, request)
    end

    private
    def client
      @client ||=
        EventMachine::Warden::FiberAwareClient.new(@connection_provider.socket_path).tap(&:connect)
    end
  end
end