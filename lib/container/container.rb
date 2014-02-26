require 'em/warden/client'
require 'vcap/component'

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

  def update_path_and_ip
    raise ArgumentError, 'container handle must not be nil' unless @handle

    request = ::Warden::Protocol::InfoRequest.new(:handle => @handle)
    response = call(:info, request)

    raise RuntimeError, 'container path is not available' unless response.container_path
    @path = response.container_path
    @host_ip = response.host_ip

    response
  end

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

  def spawn(script, resource_limits = nil)
    request =
      ::Warden::Protocol::SpawnRequest.new(handle: handle,
                                           script: script,
                                           discard_output: true)

    request.rlimits = resource_limits if resource_limits

    response = call(:app, request)

    response
  end

  def resource_limits(file_descriptor_limit, process_limit)
    ::Warden::Protocol::ResourceLimits.new(nofile: file_descriptor_limit,
                                           nproc: process_limit)
  end

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

  def create_container(params)
    [:bind_mounts, :limit_cpu, :byte, :inode, :limit_memory, :setup_network].each do |param|
      raise ArgumentError, "expecting #{param.to_s} parameter to create container" if params[param].nil?
    end

    with_em do
      new_container_with_bind_mounts(params[:bind_mounts])
      limit_cpu(params[:limit_cpu])
      limit_disk(byte: params[:byte], inode: params[:inode])
      limit_memory(params[:limit_memory])
      setup_network if params[:setup_network]
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

  def info
    request = ::Warden::Protocol::InfoRequest.new
    request.handle = @handle
    call(:app_info, request)
  end

  def link(job_id)
    call_with_retry(:link, ::Warden::Protocol::LinkRequest.new(handle: handle, job_id: job_id))
  end

  def link_or_raise(job_id)
    response = link(job_id)
    if response.exit_status > 0
      raise WardenError.new("Script exited with status #{response.exit_status}", response)
    else
      response
    end
  end

  def call(name, request)
    start_time_in_ms = (Time.now.to_f * 1_000).to_i
    client(name).call(request)
  rescue => e
    emit_warden_failure_to_varz
    raise e
  ensure
    emit_warden_response_time_to_varz((Time.now.to_f * 1_000).to_i - start_time_in_ms)
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

  def limit_disk(params)
    request_params = { handle: self.handle }
    request_params[:byte] = params[:byte] unless params[:byte].nil?
    request_params[:inode] = params[:inode] unless params[:inode].nil?

    request = ::Warden::Protocol::LimitDiskRequest.new(request_params)
    call(:app, request)
  end

  def limit_memory(bytes)
    request = ::Warden::Protocol::LimitMemoryRequest.new(handle: self.handle, limit_in_bytes: bytes)
    call(:app, request)
  end

  private

  def emit_warden_response_time_to_varz(response_time_in_ms)
    VCAP::Component.varz.synchronize do
      VCAP::Component.varz[:total_warden_response_time_in_ms] ||= 0
      VCAP::Component.varz[:total_warden_response_time_in_ms] += response_time_in_ms
      VCAP::Component.varz[:warden_request_count] ||= 0
      VCAP::Component.varz[:warden_request_count] += 1
    end
  end

  def emit_warden_failure_to_varz
    VCAP::Component.varz.synchronize do
      VCAP::Component.varz[:warden_error_response_count] ||= 0
      VCAP::Component.varz[:warden_error_response_count] += 1
    end
  end
end
