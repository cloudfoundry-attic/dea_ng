#XXX UPDATE UNIT TESTS!!!
require 'logger'
require 'benchmark'
require 'em/warden/client'
require 'etc'
require 'errors'

module VCAP module Dea end end

class VCAP::Dea::WardenEnv
  @@warden_socket_path = "/tmp/warden.sock"

  def self.set_warden_socket_path(path)
    @@warden_socket_path = path
  end

  def self.ping
    client = EM::Warden::FiberAwareClient.new(@@warden_socket_path)
    client.connect
    client.ping
    client.disconnect(false) #em will re-use connection
  end

  def initialize(logger = nil)
    @logger = logger || Logger.new(STDOUT)
    @handle = nil
    @linked = false
    setup_warden_client
    unless defined? @@user
      @@user = Etc.getpwuid(Process.uid).name
      @@group = Etc.getgrgid(Process.gid).name
    end
  end

  def fetch_handle
    raise VCAP::Dea::WardenError, "no handle set, did you call create_container or bind_container?" unless @handle
    @handle
  end

  def get_container_info
    {:handle => @handle, :jobid => @jobid}
  end

  def setup_warden_client
    warden_socket_path = "/tmp/warden.sock"
    @client = EM::Warden::FiberAwareClient.new(warden_socket_path)
    @client.connect
    @client.ping
  end

  def get_stats
    return nil unless @linked
    handle = fetch_handle
    client = EM::Warden::FiberAwareClient.new(@@warden_socket_path)
    client.connect
    info = client.info(handle)
    client.disconnect(false) #em will re-use connection
    stats =  info['stats']
    {:mem_usage_B => stats['mem_usage_B'], :disk_usage_B => stats['disk_usage_B']}
  end

  def ping
    @client.ping
  end

  def build_mounts_list(mounts)
    mount_list = []
    mounts.each { |src, dst, mode| mount_list.push([src, dst, {"mode" => mode}])}
    mount_list
  end

  def alloc_network_port
    @client.net(fetch_handle, 'in')["host_port"]
  end

  def bind_container(container_info)
    #XXX validate container info
    @handle = container_info[:handle]
    @jobid  = container_info[:jobid]
  end

  def create_container(mounts = nil, resource_limits = nil)
    config = {}
    config['bind_mounts'] = build_mounts_list(mounts) if mounts
    config['disk_size_mb'] = resource_limits[:disk] if resource_limits && resource_limits[:disk]
    start_time = Time.now
    if config.empty?
      @handle = @client.create
    else
      @logger.debug("creating container with config #{config.to_s}")
      @handle = @client.create(config)
    end

    @client.limit(@handle, 'mem', resource_limits[:memory]) if resource_limits && resource_limits[:memory]
    end_time = Time.now
    total_time = end_time - start_time

    raise VCAP::Dea::WardenError, "container creation failed with #{@handle}" if @handle =~ /failure/
    @logger.debug("created container #{@handle}: with mounts:#{mounts} resources: #{resource_limits}, took (#{total_time})")
  end

  def copy_in(src_path, dst_path)
    handle = fetch_handle
    raise VCAP::Dea::WardenError, "invalid path #{src_path}" if not File.exists?(src_path)
    start_time = Time.now
    result = @client.copy(handle, 'in', src_path, dst_path)
    end_time = Time.now
    total_time = end_time - start_time
    raise VCAP::Dea::WardenError, "copy in failed" unless result == 'ok'
    @logger.debug("copied in #{dst_path}, took (#{total_time})")
  end

  def copy_out(src_path, dst_path)
    handle = fetch_handle
    start_time = Time.now
    result = @client.copy(handle, 'out', src_path, dst_path, "#{@@user}:#{@@group}")
    end_time = Time.now
    total_time = end_time - start_time
    raise VCAP::Dea::WardenError, "copy out failed" unless result == 'ok'
    @logger.debug("copied out #{dst_path}, took (#{total_time})")
  end

  def file_exists?(path)
    cmd = "test -e #{path} && echo true"
    _,out,_ = run(cmd)
    out.chop == 'true'
  end

  def run(cmd)
    handle = fetch_handle
    start_time = Time.now
    result = @client.run(handle, cmd)
    end_time = Time.now
    total_time = end_time - start_time
    #XXX log different for now.
    #@logger.debug("run #{cmd}:took (#{total_time}) returned: #{result.to_s}")
    result
  end

  def spawn(cmd)
    handle = fetch_handle
    start_time = Time.now
    @jobid = @client.spawn(handle, cmd)
    end_time = Time.now
    total_time = end_time - start_time
    @logger.debug("spawn #{cmd}:took (#{total_time}) returned: #{@jobid}")
    @jobid
  end

  def link
    handle = fetch_handle
    raise VCAP::Dea::WardenError, "no jobid to link to" unless @jobid
    begin
      @linked = true
      result = @client.link(handle, @jobid)
      @linked = false
    rescue => e
      @logger.warn "error on link - possible warden restart. #{e.message}"
      raise VCAP::Dea::WardenError, "link failed"
    ensure
      @client.disconnect(false) if result[0] == nil #drop connection if container has been destroyed.
    end
    @logger.debug("link returned: #{result}")
    result
  end

  def destroy!
    handle = fetch_handle
    #if another fiber is blocked in a link, we can't reuse its connection
    #create a new connection, then use it to blow away the container
    #and rely on link to disconnect upon return.
    begin
      killer = nil
      if not @linked
        @client.disconnect(false)
      else
        killer = EM::Warden::FiberAwareClient.new(@@warden_socket_path)
        killer.connect
        killer.destroy(handle)
      end
    rescue => e
      @logger.warn("failed to destroy container #{handle}: #{e.message}.")
    ensure
      killer.disconnect(false) if killer
    end
    @logger.debug("destroyed container #{handle}.")
    @handle = @jobid = nil
  end
end

