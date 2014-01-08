require 'em/warden/client'

class Container
  class WardenError < StandardError
    attr_reader :result

    def initialize(message, response=nil)
      super(message)
      @result = response
    end
  end

  BIND_MOUNT_MODE_MAP = {
    'ro' => ::Warden::Protocol::CreateRequest::BindMount::Mode::RO,
    'rw' => ::Warden::Protocol::CreateRequest::BindMount::Mode::RW,
  }

  attr_reader :path, :host_ip, :network_ports
  attr_accessor :handle

  def initialize(client_provider)
    @client_provider = client_provider
    @path = nil
    @network_ports = {}
  end

  #API: GETSTATE (returns the warden's state file)
  def update_path_and_ip
    raise ArgumentError, 'container handle must not be nil' unless @handle

    request = ::Warden::Protocol::InfoRequest.new(:handle => @handle)
    response = call(:info, request)

    raise RuntimeError, 'container path is not available' unless response.container_path
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

  def with_em(&blk)
    if EM.reactor_running?
      blk.call
    else
      EM.run do
        f = Fiber.new do
          begin
            blk.call
          ensure
            EM.stop
          end
        end
        f.resume
      end
    end

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
      logger.error(error)
      retry
    end

    if count > 0
      logger.debug("Request succeeded after #{count} retries: #{request.inspect}")
    end
    response
  end

  #API: RUNSCRIPT
  def run_script(name, script, privileged=false, discard_output=false, log_tag=nil)
    request = ::Warden::Protocol::RunRequest.new
    request.handle = handle
    request.script = script
    request.privileged = privileged
    request.discard_output = discard_output
    request.log_tag = log_tag

    response = call(name, request)
    if response.exit_status > 0
      data = {
        :script => script,
        :exit_status => response.exit_status,
        :stdout => response.stdout,
        :stderr => response.stderr,
      }
      logger.warn('%s exited with status %d with data %s' % [script.inspect, response.exit_status, data.inspect])
      raise WardenError.new("Script exited with status #{response.exit_status}", response)
    else
      response
    end
  end

  #API: SPAWN
  def spawn(script, file_descriptor_limit, nproc_limit, discard_output=false, log_tag=nil)
    request = ::Warden::Protocol::SpawnRequest.new
    request.handle = handle
    request.rlimits = ::Warden::Protocol::ResourceLimits.new
    request.rlimits.nproc = nproc_limit
    request.rlimits.nofile = file_descriptor_limit
    request.script = script
    request.discard_output = discard_output
    request.log_tag = log_tag
    response = call(:app, request)
    response
  end

  #API: DESTROY
  def destroy!
    with_em do
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

  def create_container(bind_mounts, cpu_limit_in_shares, disk_limit_in_bytes, memory_limit_in_bytes, network)
    with_em do
      new_container_with_bind_mounts(bind_mounts)
      limit_cpu(cpu_limit_in_shares)
      limit_disk(disk_limit_in_bytes)
      limit_memory(memory_limit_in_bytes)
      setup_network if network
    end
  end

  def new_container_with_bind_mounts(bind_mounts)
    with_em do
      create_request = ::Warden::Protocol::CreateRequest.new
      create_request.bind_mounts = bind_mounts.map do |bm|

        bind_mount = ::Warden::Protocol::CreateRequest::BindMount.new
        bind_mount.src_path = bm['src_path']
        bind_mount.dst_path = bm['dst_path'] || bm['src_path']

        mode = bm['mode'] || 'ro'
        bind_mount.mode = BIND_MOUNT_MODE_MAP[mode]
        bind_mount
      end

      response = call(:app, create_request)
      self.handle = response.handle
    end
  end

  # HELPER for DESTROY
  def close_all_connections
    @client_provider.close_all
  end

  def setup_network
    request = ::Warden::Protocol::NetInRequest.new(handle: handle)
    response = call(:app, request)
    network_ports['host_port'] = response.host_port
    network_ports['container_port'] = response.container_port

    request = ::Warden::Protocol::NetInRequest.new(handle: handle)
    response = call(:app, request)
    network_ports['console_host_port'] = response.host_port
    network_ports['console_container_port'] = response.container_port
  end

  # HELPER
  def info
    request = ::Warden::Protocol::InfoRequest.new
    request.handle = @handle
    call(:app_info, request)
  end

  # HELPER
  def call(name, request)
    client(name).call(request)
  end

  def stream(request, &blk)
    client(:app).stream(request, &blk)
  end

  def client(name)
    @client_provider.get(name)
  end

  def limit_cpu(shares)
    request = ::Warden::Protocol::LimitCpuRequest.new(handle: self.handle, limit_in_shares: shares)
    call(:app, request)
  end

  def limit_disk(bytes)
    request = ::Warden::Protocol::LimitDiskRequest.new(handle: self.handle, byte: bytes)
    call(:app, request)
  end

  def limit_memory(bytes)
    request = ::Warden::Protocol::LimitMemoryRequest.new(handle: self.handle, limit_in_bytes: bytes)
    call(:app, request)
  end
end
