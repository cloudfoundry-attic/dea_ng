require 'em/warden/client'
require 'vcap/component'
require 'dea/utils/egress_rules_mapper'

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

  attr_accessor :handle
  attr_reader :path, :host_ip, :network_ports

  def initialize(client_provider)
    @client_provider = client_provider
    @path = nil
    @network_ports = {}
  end

  def update_path_and_ip
    raise ArgumentError, 'container handle must not be nil' unless handle

    response = call(:info, ::Warden::Protocol::InfoRequest.new(handle: handle))

    raise RuntimeError, 'container path is not available' unless response.container_path
    @path = response.container_path
    @host_ip = response.host_ip

    response
  end

  def get_new_warden_net_in
    call(:app, ::Warden::Protocol::NetInRequest.new(handle: handle))
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
    request = ::Warden::Protocol::RunRequest.new(handle: handle,
                                                 script: script,
                                                 privileged: privileged,
                                                 discard_output: discard_output,
                                                 log_tag: log_tag)

    response = call(name, request)
    if response.exit_status > 0
      data = {
          script: script,
          exit_status: response.exit_status,
          stdout: response.stdout,
          stderr: response.stderr,
      }
      logger.warn('%s exited with status %d with data %s' % [script.inspect, response.exit_status, data.inspect])
      raise WardenError.new("Script exited with status #{response.exit_status}", response)
    else
      response
    end
  end

  def spawn(script, resource_limits = nil)
    spawn_params = {
        handle: handle,
        script: script,
        discard_output: true
    }
    spawn_params[:rlimits] = resource_limits if resource_limits

    call(:app, ::Warden::Protocol::SpawnRequest.new(spawn_params))
  end

  def resource_limits(file_descriptor_limit, process_limit)
    ::Warden::Protocol::ResourceLimits.new(nofile: file_descriptor_limit, nproc: process_limit)
  end

  def destroy!
    with_em do
      begin
        call_with_retry(:app, ::Warden::Protocol::DestroyRequest.new(handle: handle))
      rescue ::EM::Warden::Client::Error => error
        logger.warn("Error destroying container: #{error.message}")
      end

      @handle = nil
    end
  end

  def create_container(params)
    [:bind_mounts, :limit_cpu, :byte, :inode, :limit_memory, :setup_inbound_network].each do |param|
      raise ArgumentError, "expecting #{param.to_s} parameter to create container" if params[param].nil?
    end

    with_em do
      new_container_with_bind_mounts(params[:bind_mounts])
      limit_cpu(params[:limit_cpu])
      limit_disk(byte: params[:byte], inode: params[:inode])
      limit_memory(params[:limit_memory])
      setup_inbound_network if params[:setup_inbound_network]
      setup_egress_rules(params[:egress_rules])
    end
  end

  def setup_egress_rules(rules)
    logger.debug("setting up egress rules: #{rules}")
    ::EgressRulesMapper.new(rules, handle).map_to_warden_rules.each do |request|
      response = call(:app, request)
    end
  end

  def new_container_with_bind_mounts(bind_mounts)
    with_em do
      bind_mount_requests =
          bind_mounts.map do |bm|
            src_path = bm['src_path']
            dst_path = bm['dst_path'] || src_path
            mode_key = bm['mode'] || 'ro'

            bind_mount_params = {
                src_path: src_path,
                dst_path: dst_path,
                mode: BIND_MOUNT_MODE_MAP[mode_key]
            }

            ::Warden::Protocol::CreateRequest::BindMount.new(bind_mount_params)
          end

      response = call(:app, ::Warden::Protocol::CreateRequest.new(bind_mounts: bind_mount_requests))

      @handle = response.handle
    end
  end

  def close_all_connections
    @client_provider.close_all
  end

  def setup_inbound_network
    response = call(:app, ::Warden::Protocol::NetInRequest.new(handle: handle))
    network_ports['host_port'] = response.host_port
    network_ports['container_port'] = response.container_port
  end

  def info
    call(:app_info, ::Warden::Protocol::InfoRequest.new(handle: handle))
  end

  def list
    call(:list, ::Warden::Protocol::ListRequest.new)
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
    elapsed_time = (Time.now.to_f * 1_000).to_i - start_time_in_ms
    emit_warden_response_time_to_varz(elapsed_time)
  end

  def stream(request, &blk)
    client(:app).stream(request, &blk)
  end

  def client(name)
    @client_provider.get(name)
  end

  def limit_cpu(shares)
    call(:app, ::Warden::Protocol::LimitCpuRequest.new(handle: handle, limit_in_shares: shares))
  end

  def limit_disk(params)
    request_params = { handle: handle }
    request_params[:byte] = params[:byte] unless params[:byte].nil?
    request_params[:inode] = params[:inode] unless params[:inode].nil?

    call(:app, ::Warden::Protocol::LimitDiskRequest.new(request_params))
  end

  def limit_memory(bytes)
    call(:app, ::Warden::Protocol::LimitMemoryRequest.new(handle: handle, limit_in_bytes: bytes))
  end

  private

  def with_em(&blk)
    if EM.reactor_running?
      blk.call
    else
      EM.run do
        Fiber.new do
          begin
            blk.call
          ensure
            EM.stop
          end
        end.resume
      end
    end
  end

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
