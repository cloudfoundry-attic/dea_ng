# coding: UTF-8

require "steno"
require "steno/config"
require "steno/core_ext"
require "vcap/common"
require "vcap/component"

require "dea/config"
require "dea/directory_server"
require "dea/droplet_registry"
require "dea/instance"
require "dea/instance_registry"
require "dea/nats"
require "dea/protocol"
require "dea/resource_manager"
require "dea/router_client"

module Dea
  class Bootstrap
    DEFAULT_HEARTBEAT_INTERVAL     = 10 # In secs
    DEFAULT_ADVERTISE_INTERVAL     = 5

    DISCOVER_DELAY_MS_PER_INSTANCE = 10
    DISCOVER_DELAY_MS_MEM          = 100
    DISCOVER_DELAY_MS_MAX          = 250

    CRASHES_REAPER_INTERVAL_SECS   = 10

    attr_reader :config
    attr_reader :nats
    attr_reader :uuid

    def initialize(config = {})
      @config = Config::EMPTY_CONFIG.merge(config)
    end

    def local_ip
      @local_ip ||= VCAP.local_ip(config["local_route"])
    end

    def validate_config
      Config.schema.validate(config)
    end

    def setup
      validate_config

      setup_logging
      setup_runtimes
      setup_droplet_registry
      setup_resource_manager
      setup_instance_registry
      setup_signal_handlers
      setup_directories
      setup_pid_file
      setup_sweepers
      setup_directory_server
      setup_nats
      setup_router_client
    end

    def setup_logging
      logging = config["logging"]

      options = {
        :sinks => [],
      }

      if logging["level"]
        options[:default_log_level] = logging["level"].to_sym
      end

      if logging["file"]
        options[:sinks] << Steno::Sink::IO.for_file(logging["file"])
      end

      if logging["syslog"]
        Steno::Sink::Syslog.instance.open(logging["syslog"])
        options[:sinks] << Steno::Sink::Syslog.instance
      end

      if options[:sinks].empty?
        options[:sinks] << Steno::Sink::IO.new(STDOUT)
      end

      Steno.init(Steno::Config.new(options))
    end

    attr_reader :runtimes

    def setup_runtimes
      runtimes = Hash[config["runtimes"].map do |name, config|
        [name, Runtime.new(config)]
      end]

      # Remove invalid runtimes
      runtimes.keys.each do |name|
        begin
          runtimes[name].validate
        rescue Runtime::BaseError => err
          logger.warn err.to_s
          runtimes.delete(name)
        end
      end

      if runtimes.empty?
        logger.fatal "No valid runtimes"
        exit 1
      end

      @runtimes = runtimes

      nil
    end

    attr_reader :droplet_registry

    def setup_droplet_registry
      @droplet_registry = Dea::DropletRegistry.new(File.join(config["base_dir"], "droplets"))
    end

    attr_reader :resource_manager

    def setup_resource_manager
      @resource_manager = Dea::ResourceManager.new(config["resources"])
    end

    attr_reader :instance_registry

    def setup_instance_registry
      @instance_registry = Dea::InstanceRegistry.new
    end

    attr_reader :router_client

    def setup_router_client
      @router_client = Dea::RouterClient.new(self)
    end

    def setup_signal_handlers
      @old_signal_handlers = {}

      %W(TERM INT QUIT USR1 USR2).each do |signal|
        @old_signal_handlers[signal] = ::Kernel.trap(signal) do
          logger.warn "caught SIG#{signal}"
          send("trap_#{signal.downcase}")
        end
      end
    end

    def teardown_signal_handlers
      @old_signal_handlers.each do |signal, handler|
        if handler.respond_to?(:call)
          # Block handler
          ::Kernel::trap(signal, &handler)
        else
          # String handler
          ::Kernel::trap(signal, handler)
        end
      end
    end

    def with_signal_handlers
      begin
        setup_signal_handlers
        yield
      ensure
        teardown_signal_handlers
      end
    end

    def trap_term
      exit
    end

    def trap_int
      exit
    end

    def trap_quit
      exit
    end

    def trap_usr1
      exit
    end

    def trap_usr2
      exit
    end

    def setup_directories
      %W(db droplets instances tmp).each do |dir|
        FileUtils.mkdir_p(File.join(config["base_dir"], dir))
      end
    end

    def setup_pid_file
      path = config["pid_filename"]

      begin
        pid_file = VCAP::PidFile.new(path, false)
        pid_file.unlink_at_exit
      rescue => err
        logger.error "Cannot create pid file at #{path} (#{err})"
        raise
      end
    end

    def setup_sweepers
      # Heartbeats of instances we're managing
      hb_interval = config["intervals"]["heartbeat"] || DEFAULT_HEARTBEAT_INTERVAL
      EM.add_periodic_timer(hb_interval) { send_heartbeat(instance_registry.to_a) }

      # Notifications for CloudControllers looking to place droplets
      advertise_interval = config["intervals"]["advertise"] || DEFAULT_ADVERTISE_INTERVAL
      EM.add_periodic_timer(advertise_interval) { send_advertise }

      # Ensure we keep around only the most recent crash for short amount of time
      EM.add_periodic_timer(CRASHES_REAPER_INTERVAL_SECS) { reap_crashes }
    end

    attr_reader :directory_server

    def setup_directory_server
      @directory_server = Dea::DirectoryServer.new(local_ip,
                                                   config["directory_server_port"],
                                                   instance_registry)
    end

    def start_directory_server
      @directory_server.start
    end

    def setup_nats
      @nats = Dea::Nats.new(self, config)
    end

    def start_nats
      @nats.start
    end

    def start_component
      VCAP::Component.register(
        :type     => "DEA",
        :host     => local_ip,
        :index    => config["index"],
        :config   => config,
        :nats     => nats,
        :port     => config["status"]["port"],
        :user     => config["status"]["user"],
        :password => config["status"]["password"])

      @uuid = VCAP::Component.uuid
    end

    def start_finish
      nats.publish("dea.start", Dea::Protocol::V1::HelloMessage.generate(self))

      send_advertise
    end

    def start
      start_component
      start_nats
      start_directory_server
      start_finish
    end

    def create_instance(attributes)
      instance = Instance.new(self, Instance.translate_attributes(attributes))

      instance.on(Instance::Transition.new(:born, :starting)) do
        instance_registry.register(instance)
      end

      instance.on(Instance::Transition.new(:starting, :crashed)) do
        instance_registry.unregister(instance)
      end

      instance.on(Instance::Transition.new(:starting, :running)) do
        # Notify others immediately
        send_heartbeat([instance])

        # Register with router
        router_client.register_instance(instance)
      end

      instance
    end

    def handle_health_manager_start(message)
      send_heartbeat(instance_registry.to_a)
    end

    def handle_router_start(message)
      instance_registry.each do |instance|
        next if !instance.running? || instance.application_uris.empty?
        router_client.register_instance(instance)
      end
    end

    def handle_dea_status(message)
      message.respond(Dea::Protocol::V1::DeaStatusResponse.generate(self))
    end

    def handle_dea_directed_start(message)
      instance = create_instance(message.data)

      begin
        instance.validate
      rescue => error
        logger.warn "Error validating instance: #{error.message}"
        return
      end

      instance.start
    end

    def handle_dea_locate(message)
      send_advertise
    end

    def handle_dea_stop(message)
      instances_filtered_by_message(message) do |instance|
        next if !instance.running?

        # Unregister with router
        router_client.unregister_instance(instance)

        instance.stop do |error|
          if error
            logger.log_exception(error)
            next
          end
        end
      end
    end

    def handle_dea_discover(message)
      runtime = message.data["runtime"]
      rs = message.data["limits"]

      if !runtimes.has_key?(runtime)
        logger.info("Unsupported runtime '#{runtime}'")
        return
      elsif !resource_manager.could_reserve?(rs["mem"], rs["disk"], 1)
        logger.info("Couldn't accomodate resource request")
        return
      end

      delay = calculate_discover_delay(message.data["droplet"])

      logger.debug("Delaying discover response for #{delay} secs.")

      resp = Dea::Protocol::V1::HelloMessage.generate(self)
      EM.add_timer(delay) { message.respond(resp) }
    end

    def calculate_discover_delay(app_id)
      delay = 0.0
      mem = resource_manager.resources["memory"]

      # Penalize for instances of the same app
      instances = instance_registry.instances_for_application(app_id)
      delay += (instances.size * DISCOVER_DELAY_MS_PER_INSTANCE)

      # Penalize for mem usage
      delay += (mem.used / mem.capacity.to_f) * DISCOVER_DELAY_MS_MEM

      [delay, DISCOVER_DELAY_MS_MAX].min.to_f / 1000
    end

    def handle_dea_update(message)
      app_id = message.data["droplet"]
      uris = message.data["uris"]

      instance_registry.instances_for_application(app_id).each do |_, instance|
        current_uris = instance.application_uris

        logger.debug("Mapping new URIs")
        logger.debug("New: #{uris} Old: #{current_uris}")

        new_uris = uris - current_uris
        unless new_uris.empty?
          router_client.register_instance(instance, :uris => new_uris)
        end

        obsolete_uris = current_uris - uris
        unless obsolete_uris.empty?
          router_client.unregister_instance(instance, :uris => obsolete_uris)
        end

        instance.application_uris = uris
      end
    end

    def handle_dea_find_droplet(message)
      include_stats = !!message.data["include_stats"]

      instances_filtered_by_message(message) do |instance|
        response = Dea::Protocol::V1::FindDropletResponse.generate(self,
                                                                   instance,
                                                                   include_stats)
        message.respond(response)
      end

      nil
    end

    def handle_droplet_status(message)
      instance_registry.each do |instance|
        next unless instance.starting? || instance.running?
        resp = Dea::Protocol::V1::DropletStatusResponse.generate(instance)
        message.respond(resp)
      end
    end

    def send_heartbeat(instances)
      return if instances.empty?

      hbs = Dea::Protocol::V1::HeartbeatResponse.generate(self, instances)
      nats.publish("dea.heartbeat", hbs)

      nil
    end

    def send_advertise
      # TODO: Return if resources are exhausted
      msg = Dea::Protocol::V1::AdvertiseMessage.generate(self)
      @nats.publish("dea.advertise", msg)
    end

    def instances_filtered_by_message(message)
      app_id = message.data["droplet"]

      if app_id
        logger.debug2("Filter message for app_id: %d" % app_id, :app_id => app_id)
      else
        logger.warn("Filter message missing app_id")
        return
      end

      instances = instance_registry.instances_for_application(app_id)
      if instances.empty?
        logger.debug2("No instances found for app_id: %d" % app_id, :app_id => app_id)
        return
      end

      set_or_nil = lambda { |h, k| h.has_key?(k) ? Set.new(h[k]) : nil }

      # Optional search filters
      version       = message.data["version"]
      instance_ids  = set_or_nil.call(message.data, "instances")
      indices       = set_or_nil.call(message.data, "indices")
      states        = set_or_nil.call(message.data, "states")

      instances.each do |_, instance|
        matched = true

        matched &&= (instance.application_version == version)   unless version.nil?
        matched &&= instance_ids.include?(instance.instance_id) unless instance_ids.nil?
        matched &&= indices.include?(instance.instance_index)   unless indices.nil?
        matched &&= states.include?(instance.state)             unless states.nil?

        if matched
          yield(instance)
        end
      end
    end

    def reap_crashes
      logger.debug2 "Reaping crashes"

      crashes_by_app = Hash.new { |h, k| h[k] = [] }
      instance_registry.select { |i| i.crashed? } \
                       .each   { |i| crashes_by_app[i.application_id] << i }

      now = Time.now.to_i

      crashes_by_app.each do |app_id, instances|
        # Most recent crashes first
        instances.sort! { |a, b| b.state_timestamp <=> a.state_timestamp }

        instances.each_with_index do |instance, idx|
          secs_since_crash = now - instance.state_timestamp

          # Remove if not most recent, or too old
          if (idx > 0) || (secs_since_crash > self.config["crash_lifetime_secs"])
            logger.info "Removing crash for #{instance.application_name}"

            instance.destroy_crash_artifacts
            instance_registry.unregister(instance)
          end
        end
      end
    end

    private

    def logger
      @logger ||= self.class.logger
    end
  end
end
