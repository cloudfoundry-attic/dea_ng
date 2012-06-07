require 'eventmachine'
require 'pp'
require 'logger'
require 'em/warden/client'
require 'tmpdir'
require 'fiber'

require 'vcap/common'
require 'vcap/logging'

require 'vcap/dea/errors'
require 'vcap/dea/fiber_aware_helpers'
require 'vcap/dea/http_util'
require 'vcap/dea/resource_tracker'
require 'vcap/dea/version'
require 'vcap/dea/snapshot'
require 'vcap/dea/convert'
require 'vcap/dea/env_builder'

require 'vcap/dea/app_cache'
require 'vcap/dea/warden_env'

module VCAP module Dea end end

class VCAP::Dea::Handler
  include VCAP::Dea::FiberAwareHelpers
  include VCAP::Dea::Convert

  attr_reader :uuid

  def initialize(params, logger = nil)
    @logger             = logger || Logger.new(STDOUT)
    @uuid               = nil
    @local_ip           = VCAP.local_ip
    @num_cores          = VCAP.num_cores
    @logger.info "Local ip: #{@local_ip}."
    @logger.info "Using #{@num_cores} cores."
    @runtimes = params[:runtimes]
    @directories = params[:directories]
    @logger.info "Supported runtimes: #{@runtimes.keys}."
    @varz = {}
    @droplets = {}
    limits = params[:resources][:node_limits]
    init_resources = {:memory => limits[:max_memory],
                      :disk => limits[:max_disk],
                      :instances => limits[:max_instances]}
    @resource_tracker = VCAP::Dea::ResourceTracker.new(init_resources, @logger)
    @default_app_quota = params[:resources][:default_app_quota]
    @logger.info("Default app quota:#{@default_app_quota}.")

    @app_cache = VCAP::Dea::AppCache.new(@directories, @logger)
    @snapshot = VCAP::Dea::Snapshot.new(@directories['db'], @logger)
  end

  def set_uuid(uuid)
    @uuid = uuid
  end

  def fetch_and_update_varz
    @varz[:apps_max_memory] = @resource_tracker.max[:memory]
    @varz[:apps_reserved_memory] = @resource_tracker.reserved[:memory]
    @varz[:apps_used_memory] = 000 #XXX fill me in
    @varz[:num_apps] = @resource_tracker.reserved[:instances]
    @varz
  end

  def get_advertise
    #XXX return nil if !space_available?
    msg = { :id => @uuid,
            :available_memory => @resource_tracker.available[:memory],
            :runtimes => @runtimes.keys}
    msg
  end

  def generate_heartbeat(instance)
    {
      :droplet => instance[:droplet_id],
      :version => instance[:version],
      :instance => instance[:instance_id],
      :index => instance[:instance_index],
      :state => instance[:state],
      :state_timestamp => instance[:state_timestamp]
    }
  end

  def get_heartbeat
    return if nil if @droplets.empty?
    heartbeat = {:droplets => [], :dea => @uuid }
    @droplets.each_value do |instances|
      instances.each_value do |instance|
        heartbeat[:droplets] << generate_heartbeat(instance)
      end
    end
    heartbeat
  end

  def handle_hm_start
    msg.respond('dea.heartbeat', get_heartbeat)
  end

  def register_instance_with_router(msg, instance, options = {})
    return unless (instance and instance[:uris] and not instance[:uris].empty?)
    msg.respond('router.register', {
                   :dea  => @uuid,
                   :host => @local_ip,
                   :port => instance[:port],
                   :uris => options[:uris] || instance[:uris],
                   :tags => {:framework => instance[:framework], :runtime => instance[:runtime]}
                 })
  end

  def unregister_instance_from_router(msg, instance, options = {})
    return unless (instance and instance[:uris] and not instance[:uris].empty?)
    msg.respond('router.unregister', {
                   :dea  => @uuid,
                   :host => @local_ip,
                   :port => instance[:port],
                   :uris => options[:uris] || instance[:uris]
                   })
  end


  def handle_router_start(msg)
    @logger.debug("got router start")
    @droplets.each_value do |instances|
      instances.each_value do |instance|
        register_instance_with_router(msg, instance) if instance[:state] == :RUNNING
      end
    end
  end

  def handle_status(msg)
    status_msg = {:id  => @uuid,
                  :ip => @local_ip,
                  :version => VCAP::Dea::VERSION,
                  :port => 0, #XXX this is just a place holder, not meaningful in DEA2
    }

    status_msg[:max_memory] = @resource_tracker.max[:memory]
    status_msg[:reserved_memory] = @resource_tracker.reserved[:memory]
    status_msg[:used_memory] = 0 #XXX fill me in once we track usage dynamically
    status_msg[:num_clients] = @resource_tracker.reserved[:instances]

    msg.reply(status_msg)
  end

  def handle_locate(msg)
    msg.respond('dea.advertise', get_advertise)
  end

  def handle_droplet_status(msg)
    @logger.debug("got droplet status")
    @droplets.each_value do |instances|
      instances.each_value do |instance|
        next unless instance[:state] == :RUNNING
        response = {
          :name => instance[:name],
          :host => @local_ip,
          :port => instance[:port],
          :uris => instance[:uris],
          :uptime => Time.now - instance[:start],
          :mem_quota => export_mem_quota(instance),
          :disk_quota => export_disk_quota(instance),
          #XXX deprecated :fds_quota => 0
        }
        msg.reply(response)
      end
    end
  end

  def lookup_instances(droplet_id)
    instances = @droplets[droplet_id]
  end

  def delete_instance(instance)
    droplet_id = instance[:droplet_id]
    instance_id = instance[:instance_id]
    instances = lookup_instances(droplet_id)
    if instances.empty?
      @logger.warn("couldn't delete #{droplet_id}:#{instance_id}, instance not found.")
      return
    end
    instances.delete(instance_id)
    @logger.debug("deleted instance: #{instance_id}")
    if instances.empty?
      @droplets.delete(droplet_id)
      @logger.debug("deleted droplet: #{droplet_id}")
    end
  end

  def add_instance(instance)
    droplet_id = instance[:droplet_id]
    instance_id = instance[:instance_id]
    @logger.debug("adding instance w/ droplet_id #{droplet_id}, instance_id #{instance_id}")
    instances = lookup_instances(droplet_id) || {}
    instances[instance_id] = instance
    @droplets[droplet_id] = instances
    @logger.debug("added droplet/index: #{droplet_id}: #{instance[:instance_index]} to droplet list.")
  end

  def set_instance_state(instance, new_state)
    valid_states = [:RUNNING, :CRASHED, :DELETED].freeze
    raise VCAP::Dea::HandlerError, "invalid state #{new_state}" unless valid_states.include? new_state
    instance[:state] = new_state
    instance[:state_timestamp] = Time.now.to_i
    @logger.debug("set instance #{instance[:instance_id]} state to #{new_state}")
  end

  def set_exit_reason(instance, reason)
    valid_reasons = [:CRASHED, :STOPPED, :DEA_EVACUATION, :DEA_SHUTDOWN].freeze
    raise VCAP::Dea::HandlerError, "invalid reason #{reason}" unless valid_reasons.include? reason
    instance[:exit_reason] = reason
    @logger.debug("set instance:#{instance[:instance_id]} exit reason to: #{reason}")
  end

  def attach_container(instance, warden_env)
    @logger.debug("instance #{instance[:instance_id]} attached container #{warden_env.get_container_info}")
    instance[:warden_env] = warden_env
    instance[:warden_container_info] = warden_env.get_container_info
  end

  def release_container(instance)
    env = instance[:warden_env]
    unless env
      @logger.error "no container attached to instance #{instance[:instance_id]}"
      raise VCAP::Dea::HandlerError, "no container attached to instance, couldn't free"
    end
    env.destroy!
  end

  def export_mem_quota(instance)
    MB_to_bytes(instance[:resources][:memory])
  end

  def export_disk_quota(instance)
    MB_to_bytes(instance[:resources][:disk])
  end

  def setup_network_ports(warden_env, instance, debug, console)
    http_port = warden_env.alloc_network_port
    instance[:port] = http_port

    if debug
      debug_port = warden_env.alloc_network_port
      instance[:debug_ip] = @local_ip
      instance[:debug_port] = debug_port
      instance[:debug_mode] = debug
    end

    if console
      console_port = warden_env.alloc_network_port
      instance[:console_ip] = @local_ip
      instance[:console_port] = console_port
    end
  end

  def droplet_id_index_in_use?(droplet_id, instance_index)
    instances = lookup_instances(droplet_id) || {}
    instances.each_value do |instance|
      if instance[:instance_index] == instance_index && instance[:state] == :RUNNING
        return true
      end
    end
    false
  end

  def start_instance(msg)
    @logger.debug("DEA received start message: #{msg.details}")

    instance_id = VCAP.secure_uuid

    droplet_id = msg.details['droplet']
    instance_index = msg.details['index']
    services = msg.details['services']
    version = msg.details['version']
    bits_file = msg.details['executableFile']
    bits_uri = msg.details['executableUri']
    name = msg.details['name']
    uris = msg.details['uris']
    sha1 = msg.details['sha1']
    app_env = msg.details['env']
    users = msg.details['users']
    runtime = msg.details['runtime'].to_sym
    framework = msg.details['framework']
    debug = msg.details['debug']
    console = msg.details['console']
    limits = msg.details['limits']

    @logger.info("Trying to start instance (name: #{name} index:#{instance_index} id: #{droplet_id})")

    if droplet_id_index_in_use?(droplet_id, instance_index)
      @logger.warn("got start request for existing id:#{droplet_id} index:#{instance_index}")
      raise VCAP::Dea::HandlerError, "duplicate start request"
    end

    unless @runtimes[runtime]
      @logger.warn("Unsupported runtime '#{msg.details['runtime']}'")
      raise VCAP::Dea::HandlerError, "Runtime unsupported"
    end

    begin
      #XXX check if resource to run app are available and reserve them
      request = {:memory => limits && limits['mem'] ? limits['mem'] : @default_app_quota[:mem_quota],
                 :disk => limits && limits['disk'] ? limits['disk'] : @default_app_quota[:disk_quota],
                 :instances => 1}
      resources = @resource_tracker.reserve(request)
      raise VCAP::Dea::HandlerError, "Failed to provision resources #{request}." unless resources

      instance = {
          :droplet_id => droplet_id,
          :instance_id => instance_id,
          :instance_index => instance_index,
          :sha1 => sha1,
          :name => name,
          :dir => '/home/vcap',
          :uris => uris,
          :users => users,
          :version => version,
          :resources => resources,
          :runtime => runtime,
          :framework => framework,
          :start => Time.now,
          :state_timestamp => Time.now.to_i,
          :log_id => "(name=%s app_id=%s instance=%s index=%s)" % [name, droplet_id, instance_id, instance_index],
        }

      #check if bits already in cache, if not download them.
      existing_droplet = @app_cache.has_droplet?(sha1)
      @app_cache.download_droplet(bits_uri, sha1) unless existing_droplet
      droplet_dir = @app_cache.droplet_dir(sha1)

      runtime_path = @runtimes[runtime][:executable]
      runtime_dir = File.dirname(File.dirname(runtime_path))

      mounts = [droplet_dir, runtime_dir]
      warden_env = VCAP::Dea::WardenEnv.new(@logger)
      warden_env.create_container(mounts, resources)
      setup_network_ports(warden_env, instance, debug, console)

      env_builder = VCAP::Dea::EnvBuilder.new(@runtimes, @local_ip, @logger)
      new_env = env_builder.setup_instance_env(instance, app_env, services)
      @logger.debug("new_env #{new_env}")

      status, out, err = warden_env.run("cp -r #{droplet_dir}/* .")
      raise VCAP::Dea::HandlerError, "Failed to copy droplet bits:#{out}:#{err}" unless status == 0

      #XXX FIXME
      #XXX sed lets us delimit our pattern with any charecter, we use @ to avoid frobbing path names
      #XXX this could screw us if a runtime path contains @, should do something safer here

      warden_env.run("sed s@%VCAP_LOCAL_RUNTIME%@#{runtime_path}@ < startup > startup.ready; chmod u+x startup.ready")
      env_str = new_env.join(" ")

      #add to instance list and let it rip.

      #XXX think about the order of this and potential failures
      set_instance_state(instance, :RUNNING)
      add_instance(instance)
      warden_env.spawn("./startup.ready -p #{instance[:port]}")
      attach_container(instance, warden_env)
      result = warden_env.link
      app_exit_handler(instance, result)
    rescue => e
      @logger.error "error while provisioning instance #{instance_id}:#{e.message}"
      @logger.error e.backtrace.join("\n")
      #XXX delete instance
      #XXX try to use remove_and_clean_up_instance here. and get rid of the !existing droplet stuff.
      @app_cache.purge_droplet!(sha1) if @app_cache.has_droplet?(sha1) and !existing_droplet
      @resource_tracker.release(resources) if resources
      warden_env.destroy! if warden_env
      raise e
    end
  end

  def app_exit_handler(instance, result)
    instance_id = instance[:instance_id]
    status, out, err = result
    @logger.info("instance #{instance_id} exited,<#{status}, out: #{out}, err: #{err}")
    if status != nil && instance[:state] == :RUNNING
      set_instance_state(instance, :CRASHED)
      set_exit_reason(instance, :CRASHED)
    end
    #XXX stash log files.
    #XXX check status code, deal with app startup failure.
  end

  CRASHED_EXPIRATION_TIME = 10 #XXX make this longer for production

  def remove_expired_crashed_apps
    @droplets.each_value do |instances|
      instances.each_value do |instance|
        if instance[:state] == :CRASHED && (Time.now.to_i - instance[:state_timestamp]) > CRASHED_EXPIRATION_TIME
            @logger.debug("Crashed instance: #{instance[:instance_id]} has expired.")
            remove_and_clean_up_instance(instance)
        end
      end
    end
  end

  def remove_unused_droplets
    all_droplets = @app_cache.list_droplets
    live_droplets = []
    @droplets.each_value do |instances|
      instances.each_value do |instance|
        live_droplets.push(instance[:sha1])
      end
    end
    dead_droplets = all_droplets - live_droplets
    @logger.debug("removing unused droplets:#{dead_droplets}") unless dead_droplets.empty?
    dead_droplets.each { |sha1| @app_cache.purge_droplet!(sha1) }
  end

  def resume_detached_containers
    @droplets.each_value do |instances|
      instances.each_value do |instance|
        if instance[:state] != :CRASHED
          resume_instance(instance)
        end
      end
    end
  end

  def resume_instance(instance)
    @logger.info("trying to resume instance #{instance[:instance_id]}")
    warden_env = VCAP::Dea::WardenEnv.new(@logger)
    container_info = instance[:warden_container_info]
    warden_env.bind_container(container_info)
    attach_container(instance, warden_env)
    begin
      result = warden_env.link
    rescue VCAP::Dea::WardenError => e
      @logger.warn("failed to resume instance #{instance[:instance_id]}:#{e.message}, cleaning up...")
      remove_and_clean_up_instance(instance)
      return
    end
    app_exit_handler(instance, result)
    #XXX add some exception handling here since this won't get caught by
    #XXX the normal event dispatch handler.
  end

  def handle_stop(msg)
    @logger.debug("got stop message #{msg.details.to_s}")
    instances = lookup_matching_instances(msg)
    return unless instances
    instances.each do |instance|
      return if instance[:state] == :DELETED
      set_instance_state(instance, :DELETED)
      set_exit_reason(instance, :STOPPED)
      stop_droplet(msg, instance)
    end
  end

  def send_exited_notification(msg, instance)
    return if instance[:evacuated]
    exit_message = {
      :droplet => instance[:droplet_id],
      :version => instance[:version],
      :instance => instance[:instance_id],
      :index => instance[:instance_index],
      :reason => instance[:exit_reason],
    }
    exit_message[:crash_timestamp] = instance[:state_timestamp] if instance[:state] == :CRASHED
    exit_message = exit_message.to_json
    msg.respond('droplet.exited', exit_message)
    @logger.debug("Sent droplet.exited #{exit_message}")
  end

  def send_exited_message(msg, instance)
    raise VCAP::Dea::HandlerError, "failed to set exit reason" unless instance[:exit_reason]
    unregister_instance_from_router(msg, instance)
    send_exited_notification(msg, instance)
  end

  def stop_droplet(msg, instance)
    @logger.info("Stopping instance #{instance[:log_id]}")
    send_exited_message(msg, instance) # unplug from routers and health managers.
    remove_and_clean_up_instance(instance)
  end

  def remove_and_clean_up_instance(instance)
    @logger.debug("removing and cleaning up: #{instance[:instance_id]}")
    @resource_tracker.release(instance[:resources])
    release_container(instance)
    delete_instance(instance)
    remove_unused_droplets
  end

  def detach_droplet(msg, instance)
    @logger.info("detaching droplet #{instance[:instance_id]}")
    send_exited_message(msg, instance) # unplug from routers and health managers.
    @resource_tracker.release(instance[:resources])
  end

  #these are our only approved exit points, we snapshot in each of them.

  def snapshot_and_exit
    snapshot_app_state
    exit!
  end

  def shutdown(msg)
    @logger.info('Starting shutdown..')
    @droplets.each_pair do |id, instances|
      @logger.debug("Stopping app #{id}")
      instances.each_value do |instance|
        # skip any crashed instances
        set_exit_reason(instance, :DEA_SHUTDOWN) unless instance[:state] == :CRASHED
        detach_droplet(msg, instance)
      end
    end
    snapshot_app_state
  end

  def evacuate_apps(msg)
    @shutting_down = true
    @logger.info('Evacuating applications..')
    @droplets.each_pair do |id, instances|
      @logger.debug("Evacuating app #{id}")
      instances.each_value do |instance|
       # skip any crashed instances
        next if instance[:state] == :CRASHED
        set_exit_reason(instance, :DEA_EVACUATION)
        stop_droplet(msg, instance)
      end
    end
    snapshot_app_state
  end

  def handle_update(msg)
    @logger.debug("got dea update")
    instances = lookup_instances(msg.details['droplet'])
    return unless instances
    uris = msg.details['uris']
    instances.each_value do |instance|
      current_uris = instance[:uris]

      @logger.debug("Mapping new URIs.")
      @logger.debug("New: #{uris.pretty_inspect} Current: #{current_uris.pretty_inspect}")

      register_instance_with_router(msg, instance, :uris => (uris - current_uris))
      unregister_instance_from_router(msg, instance, :uris => (current_uris - uris))

      instance[:uris] = uris
    end
  end

  #XXX clean me up.
  def lookup_matching_instances(msg)
    matches = []
    droplet_id = msg.details['droplet']
    instances = lookup_instances(droplet_id)
    return nil unless instances
    version = msg.details['version']
    instance_ids = msg.details['instances'] ? Set.new(msg.details['instances']) : nil
    indices = msg.details['indices'] ? Set.new(msg.details['indices']) : nil
    states = msg.details['states'] ? Set.new(msg.details['states']) : nil
    instances.each_value do |instance|
      version_matched = version.nil? || instance[:version] == version
      instance_matched = instance_ids.nil? || instance_ids.include?(instance[:instance_id])
      index_matched = indices.nil? || indices.include?(instance[:instance_index])
      state_matched = states.nil? || states.include?(instance[:state].to_s)
      if version_matched && instance_matched && index_matched && state_matched
        matches.push(instance)
      end
    end
    matches
  end

  def handle_find_droplet(msg)
    @logger.debug("got find droplet")
    include_stats = msg.details['include_stats'] ? msg.details['include_stats'] : false
    instances = lookup_matching_instances(msg)
    return unless instances
    instances.each do |instance|
      response = {
        :dea => @uuid,
        :version => instance[:version],
        :droplet => instance[:droplet_id],
        :instance => instance[:instance_id],
        :index => instance[:instance_index],
        :state => instance[:state],
        :state_timestamp => instance[:state_timestamp],
        #XXX :file_uri => "http://#{@local_ip}:#{@file_viewer_port}/droplets/",
        #XXX :credentials => @file_auth,
        #XXX :staged => instance[:staged],
        :debug_ip => instance[:debug_ip],
        :debug_port => instance[:debug_port],
        :console_ip => instance[:console_ip],
        :console_port => instance[:console_port]
      }
      if include_stats && instance[:state] == :RUNNING
        response[:stats] = {
          :name => instance[:name],
          :host => @local_ip,
          :port => instance[:port],
          :uris => instance[:uris],
          :uptime => Time.now - instance[:start],
          :mem_quota => export_mem_quota(instance),
          :disk_quota => export_disk_quota(instance),
          #XXX deprecated :fds_quota => instance[:fds_quota],
          :cores => @num_cores
        }
        #XXX fix me up response[:stats][:usage] = @usage[instance[:pid]].last if @usage[instance[:pid]]
      end
      msg.reply(response)
    end
  end

  def snapshot_app_state
    @snapshot.store_snapshot(@droplets)
  end

  def convert_keys_to_symbols(hash)
    new_hash = {}
    hash.each_pair do |key, value|
      new_hash[key.to_sym] = value
    end
    new_hash
  end

  def restore_snapshot
    recovered = @snapshot.read_snapshot
    return unless recovered
    @logger.debug "trying to restore snapshot..."
    #XXX add a rescue block to catch errors and log if recovery fails...
    recovered.each_pair do |droplet_id, instances|
      @droplets[droplet_id.to_i] = instances
      instances.each_pair do |instance_id, instance|
        begin
          instances[instance_id] = instance = convert_keys_to_symbols(instance)
          @logger.debug("instance: #{instance.to_s}")
          set_instance_state(instance, instance[:state].to_sym)
          instance[:resources] = convert_keys_to_symbols(instance[:resources])
          instance[:warden_container_info] = convert_keys_to_symbols(instance[:warden_container_info])
          instance[:exit_reason] = instance[:exit_reason].to_sym if instance[:exit_reason]
          instance[:start] = Time.parse(instance[:start]) if instance[:start]

          unless @resource_tracker.reserve(instance[:resources])
            raise VCAP::Dea::HandlerError, "Failed to provision resources #{request}."
          end

          @logger.info("restored #{instance[:log_id]}, state: #{instance[:state]}")
        rescue => e
          @logger.error "encountered error recovering instance #{instance_id}"
          raise e
        end
      end
    end
    @logger.info("resources in use after restore:#{@resource_tracker.reserved}")
    remove_unused_droplets
    snapshot_app_state
  end
end
