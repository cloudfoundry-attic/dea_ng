# coding: UTF-8

require "set"

require "steno"
require "steno/config"
require "steno/core_ext"

require "loggregator_emitter"

require "thin"

require "vcap/common"
require "vcap/component"

require "dea/config"
require "container/container"
require "dea/droplet_registry"
require "dea/nats"
require "dea/protocol"
require "dea/resource_manager"
require "dea/router_client"
require "dea/loggregator"

require "dea/lifecycle/signal_handler"

require "dea/directory_server/directory_server_v2"

require "dea/utils/download"

require "dea/staging/staging_task_registry"
require "dea/staging/staging_task"

require "dea/starting/instance"
require "dea/starting/instance_uri_updater"
require "dea/starting/instance_manager"
require "dea/starting/instance_registry"

require "dea/snapshot"

Dir[File.join(File.dirname(__FILE__), "responders/*.rb")].each { |f| require(f) }

module Dea
  class Bootstrap
    DEFAULT_HEARTBEAT_INTERVAL = 10 # In secs
    DROPLET_REAPER_INTERVAL_SECS = 60

    DISCOVER_DELAY_MS_PER_INSTANCE = 10
    DISCOVER_DELAY_MS_MEM = 100
    DISCOVER_DELAY_MS_MAX = 250

    attr_reader :config
    attr_reader :nats, :responders
    attr_reader :directory_server_v2
    attr_reader :staging_task_registry
    attr_reader :uuid

    def initialize(config = {})
      @config = Config.new(config)
      @log_counter = Steno::Sink::Counter.new
    end

    def local_ip
      @local_ip ||= VCAP.local_ip
    end

    def validate_config
      config.validate
    rescue Exception => e
      # Too early in the init process, we haven't got a logger
      puts("Validation config failed with error #{e}")
      raise e
    end

    def setup
      validate_config

      setup_nats
      setup_logging
      setup_loggregator
      setup_warden_container_lister
      setup_droplet_registry
      setup_instance_registry
      setup_staging_task_registry
      setup_instance_manager
      setup_snapshot
      setup_resource_manager
      setup_router_client
      setup_directory_server_v2
      setup_directories
      setup_pid_file
      setup_sweepers
    end

    def setup_varz
      VCAP::Component.varz.synchronize do
        VCAP::Component.varz[:stacks] = config["stacks"]
      end

      EM.add_periodic_timer(DEFAULT_HEARTBEAT_INTERVAL) do
        periodic_varz_update
      end
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

      options[:sinks] << @log_counter

      Steno.init(Steno::Config.new(options))
      logger.info("Dea started")
    end

    attr_reader :warden_container_lister

    def setup_warden_container_lister
      @warden_container_lister = Container.new(WardenClientProvider.new(config["warden_socket"]))
    end

    attr_reader :droplet_registry

    def setup_droplet_registry
      @droplet_registry = Dea::DropletRegistry.new(File.join(config["base_dir"], "droplets"))
    end

    attr_reader :instance_registry

    def setup_instance_registry
      @instance_registry = Dea::InstanceRegistry.new(config)
    end

    attr_reader :instance_manager

    def setup_instance_manager
      @instance_manager = Dea::InstanceManager.new(self, nats)
    end

    attr_reader :resource_manager

    def setup_resource_manager
      @resource_manager = Dea::ResourceManager.new(
        instance_registry,
        staging_task_registry,
        config["resources"]
      )
    end

    def setup_staging_task_registry
      @staging_task_registry = Dea::StagingTaskRegistry.new
    end

    attr_reader :snapshot

    def setup_snapshot
      @snapshot = Dea::Snapshot.new(staging_task_registry, instance_registry, config["base_dir"], instance_manager)
    end

    attr_reader :router_client

    def setup_router_client
      @router_client = Dea::RouterClient.new(self)
    end

    def setup_loggregator
      if @config["loggregator"] && @config["loggregator"]["router"] && @config["loggregator"]["shared_secret"]
        Dea::Loggregator.emitter = LoggregatorEmitter::Emitter.new(@config["loggregator"]["router"], "DEA", @config["index"], @config["loggregator"]["shared_secret"])
        Dea::Loggregator.staging_emitter = LoggregatorEmitter::Emitter.new(@config["loggregator"]["router"], "STG", @config["index"], @config["loggregator"]["shared_secret"])
      end
    end

### SIG_Handlers

    def setup_signal_handlers
      @sig_handler ||= SignalHandler.new(uuid, local_ip, nats, locator_responders, instance_registry, @staging_task_registry, droplet_registry, @directory_server_v2, logger, config)
      @sig_handler.setup do |signal, &handler|
        ::Kernel.trap(signal, &handler)
      end
    end

### /SIG_Handlers
### Setup_Stuff

    def setup_directories
      %W(db droplets instances tmp staging).each do |dir|
        FileUtils.mkdir_p(File.join(config["base_dir"], dir))
      end

      FileUtils.mkdir_p(config.crashes_path)
    end

    def setup_pid_file
      path = config["pid_filename"]

      begin
        pid_file = VCAP::PidFile.new(path, false)
        pid_file.unlink_at_exit
      rescue => err
        logger.error("Cannot create pid file at #{path} (#{err})")
        raise
      end
    end

    def setup_sweepers
      # Heartbeats of instances we're managing
      hb_interval = config["intervals"]["heartbeat"] || DEFAULT_HEARTBEAT_INTERVAL
      @heartbeat_timer = EM.add_periodic_timer(hb_interval) { send_heartbeat }

      # Ensure we keep around only the most recent crash for short amount of time
      instance_registry.start_reaper

      # Remove unreferenced droplets
      EM.add_periodic_timer(DROPLET_REAPER_INTERVAL_SECS) do
        reap_unreferenced_droplets
      end
    end

    def setup_directory_server_v2
      v2_port = config["directory_server"]["v2_port"]
      @directory_server_v2 = Dea::DirectoryServerV2.new(config["domain"], v2_port, router_client, config)
      @directory_server_v2.configure_endpoints(instance_registry, staging_task_registry)
    end

    def setup_nats
      @nats = Dea::Nats.new(self, config)
    end

    def start_nats
      nats.start

      @responders = [
        Dea::Responders::DeaLocator.new(nats, uuid, resource_manager, config),
        Dea::Responders::StagingLocator.new(nats, uuid, resource_manager, config),
        Dea::Responders::Staging.new(nats, uuid, self, staging_task_registry, directory_server_v2, resource_manager, config),
      ].each(&:start)
    end

### /Setup_Stuff

    def locator_responders
      return [] unless @responders
      @responders.select do |r|
        r.is_a?(Dea::Responders::DeaLocator) ||
          r.is_a?(Dea::Responders::StagingLocator)
      end
    end

    def start_component
      VCAP::Component.register(
        :type => "DEA",
        :host => local_ip,
        :index => config["index"],
        :nats => self.nats.client,
        :port => config["status"]["port"],
        :user => config["status"]["user"],
        :password => config["status"]["password"],
        :logger => logger,
        :log_counter => @log_counter
      )

      @uuid = VCAP::Component.uuid
    end

    def start_finish
      nats.publish("dea.start", Dea::Protocol::V1::HelloMessage.generate(self))
      locator_responders.map(&:advertise)

      unless instance_registry.empty?
        logger.info("Loaded #{instance_registry.size} instances from snapshot")
        send_heartbeat()
      end
    end

    def register_directory_server_v2
      @router_client.register_directory_server(
        directory_server_v2.port,
        directory_server_v2.external_hostname
      )
    end

    def start
      snapshot.load

      start_component
      start_nats
      greet_router
      register_directory_server_v2
      directory_server_v2.start
      setup_varz

      setup_signal_handlers
      start_finish
    end

    def greet_router
      @router_client.greet do |response|
        handle_router_start(response)
      end
    end

    def reap_unreferenced_droplets
      instance_registry_shas = Set.new(instance_registry.map(&:droplet_sha1))
      staging_registry_shas = Set.new(staging_task_registry.map(&:droplet_sha1))
      all_shas = Set.new(droplet_registry.keys)

      (all_shas - instance_registry_shas - staging_registry_shas).each do |unused_sha|
        logger.debug("Removing droplet for sha=#{unused_sha}")

        droplet = droplet_registry.delete(unused_sha)
        droplet.destroy
      end
    end

### Handle_Nats_Messages

    def handle_health_manager_start(message)
      send_heartbeat()
    end

    def handle_router_start(message)
      interval = message.data.nil? ? nil : message.data["minimumRegisterIntervalInSeconds"]
      register_routes

      if interval
        EM.cancel_timer(@registration_timer) if @registration_timer

        @registration_timer = EM.add_periodic_timer(interval) do
          register_routes
        end
      end
    end

    def register_routes
      instance_registry.each do |instance|
        next if !(instance.running? || instance.evacuating?) || instance.application_uris.empty?
        router_client.register_instance(instance)
      end

      register_directory_server_v2
    end

    def handle_dea_status(message)
      message.respond(Dea::Protocol::V1::DeaStatusResponse.generate(self))
    end

    def handle_dea_directed_start(message)
      start_app(message.data)
    end

    def start_app(data)
      instance = instance_manager.create_instance(data)
      return unless instance

      instance.start
    end

    def handle_dea_stop(message)
      instance_registry.instances_filtered_by_message(message) do |instance|
        next unless instance.running? || instance.starting? || instance.evacuating?

        instance.stop do |error|
          logger.warn("Failed stopping #{instance}: #{error}") if error
        end
      end
    end

    def handle_dea_update(message)
      app_id = message.data["droplet"].to_s
      uris = message.data["uris"]
      app_version = message.data["version"]

      instance_registry.instances_for_application(app_id).dup.each do |_, instance|
        next unless instance.running? || instance.evacuating?
        InstanceUriUpdater.new(instance, uris).update(router_client)
        if app_version
          instance.application_version = app_version
          instance_registry.change_instance_id(instance)
        end
      end
    end

    def handle_dea_find_droplet(message)
      instance_registry.instances_filtered_by_message(message) do |instance|
        response = Dea::Protocol::V1::FindDropletResponse.generate(self,
          instance,
          message.data)
        message.respond(response)
      end

      nil
    end

### /Handle_Nats_Messages

    def send_staging_stop
      staging_task_registry.tasks.each do |task|
        logger.debug("Stopping staging task #{task}")
        task.stop
      end
    end

    def send_heartbeat
      instances = instance_registry.to_a.select do |instance|
        instance.starting? || instance.running? || instance.crashed? || instance.evacuating?
      end

      return if instances.empty?

      hbs = Dea::Protocol::V1::HeartbeatResponse.generate(self, instances)
      nats.publish("dea.heartbeat", hbs)

      nil
    end

    def periodic_varz_update
      mem_required = config.minimum_staging_memory_mb
      disk_required = config.minimum_staging_disk_mb
      reservable_stagers = resource_manager.number_reservable(mem_required, disk_required)
      available_memory_ratio = resource_manager.available_memory_ratio
      available_disk_ratio = resource_manager.available_disk_ratio
      warden_containers = warden_container_lister.list.handles

      VCAP::Component.varz.synchronize do
        VCAP::Component.varz[:can_stage] = (reservable_stagers > 0) ? 1 : 0
        VCAP::Component.varz[:reservable_stagers] = reservable_stagers
        VCAP::Component.varz[:available_memory_ratio] = available_memory_ratio
        VCAP::Component.varz[:available_disk_ratio] = available_disk_ratio
        VCAP::Component.varz[:instance_registry] = instance_registry.to_hash
        VCAP::Component.varz[:warden_containers] = warden_containers
      end
    end

    private

    def logger
      @logger ||= self.class.logger
    end
  end
end
