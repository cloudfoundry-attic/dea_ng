# coding: UTF-8

require "set"

require "steno"
require "steno/config"
require "steno/core_ext"

require "loggregator_emitter"

require "thin"

require "dea/config"
require "container/container"
require "dea/droplet_registry"
require "dea/nats"
require "dea/protocol"
require "dea/pid_file"
require "dea/utils"
require "dea/resource_manager"
require "dea/router_client"
require "dea/loggregator"
require "dea/lifecycle/signal_handler"
require "dea/directory_server/directory_server_v2"
require "dea/http/httpserver"
require "dea/utils/download"
require "dea/utils/hm9000"
require 'dea/utils/cloud_controller_client'
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
    DEFAULT_METRICS_INTERVAL = 30
    DROPLET_REAPER_INTERVAL_SECS = 60
    CONTAINER_REAPER_INTERVAL_SECS = 600

    DISCOVER_DELAY_MS_PER_INSTANCE = 10
    DISCOVER_DELAY_MS_MEM = 100
    DISCOVER_DELAY_MS_MAX = 250

    attr_reader :config
    attr_reader :nats, :responders
    attr_reader :directory_server_v2, :http_server
    attr_reader :staging_task_registry
    attr_reader :uuid
    attr_reader :hm9000, :cloud_controller_client
    attr_reader :staging_responder, :http_staging_responder

    def initialize(config = {})
      @config = Config.new(config)
      @log_counter = Steno::Sink::Counter.new
      @orphaned_containers = []
    end

    def local_ip
      @local_ip ||= Dea.local_ip
    end

    def uptime
      @start_time ||= Time.now
      Time.now - @start_time
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

      @uuid = SecureRandom.uuid
      setup_logging
      setup_nats
      setup_hm9000
      setup_loggregator
      setup_warden_container_lister
      setup_droplet_registry
      setup_instance_registry
      setup_staging_task_registry
      setup_instance_manager
      setup_snapshot
      setup_resource_manager
      setup_router_client
      setup_cloud_controller_client
      setup_http_server
      setup_directory_server_v2
      setup_directories
      setup_pid_file
      setup_staging_responders
    end

    def start_metrics
      EM.add_periodic_timer(DEFAULT_METRICS_INTERVAL) do
        Fiber.new do
          periodic_metrics_emit
        end.resume
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
      if @config["loggregator"] && @config["loggregator"]["router"]
        Dea::Loggregator.emitter = LoggregatorEmitter::Emitter.new(@config["loggregator"]["router"], "DEA", "DEA", @config["index"])
        Dea::Loggregator.staging_emitter = LoggregatorEmitter::Emitter.new(@config["loggregator"]["router"], "DEA", "STG", @config["index"])
      end
    end

### SIG_Handlers

    attr_reader :evac_handler, :shutdown_handler

    def setup_signal_handlers
      @evac_handler ||= EvacuationHandler.new(self, nats, locator_responders, instance_registry, @staging_task_registry, logger, config)
      @shutdown_handler ||= ShutdownHandler.new(nats, locator_responders, instance_registry, @staging_task_registry, droplet_registry, @directory_server_v2, logger)
      @sig_handler ||= SignalHandler.new(uuid, local_ip, nats, locator_responders, instance_registry, evac_handler, shutdown_handler, logger)
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
        pid_file = PidFile.new(path, false)
        pid_file.unlink_at_exit
      rescue => err
        logger.error("Cannot create pid file at #{path} (#{err})")
        raise
      end
    end

    def reap_orphaned_containers
      logger.debug("Reaping orphaned containers")

      promise_handles = Dea::Promise.new do |p|
        p.deliver warden_container_lister.list.handles
      end

      Dea::Promise.resolve(promise_handles) do |error, handles|
        if error
          logger.error(error.message)
        else
          orphaned = []
          if handles
            known_instances = instance_registry.map(&:warden_handle)
            known_stagers = staging_task_registry.map(&:warden_handle)
            orphaned = handles - ( known_instances | known_stagers )
          end
          (@orphaned_containers & orphaned).each do |handle|
            logger.debug("reaping orphaned container with handle #{handle}")
            warden_container_lister.handle = handle
            warden_container_lister.destroy!
          end
          @orphaned_containers = orphaned - (@orphaned_containers & orphaned)
        end
      end
    end

    def setup_http_server
      @http_server = Dea::HttpServer.new(self, config)
      if @http_server.enabled?
        @local_dea_service = "https://#{config['service_name']}:#{http_server.port}"
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

    def setup_hm9000
      hb_interval = config["intervals"]["heartbeat"] || DEFAULT_HEARTBEAT_INTERVAL
      @hm9000 = HM9000.new(config["hm9000"]["listener_uri"], config["hm9000"]["key_file"], config["hm9000"]["cert_file"], config["hm9000"]["ca_file"], hb_interval, logger)
    end

    def setup_cloud_controller_client
      @cloud_controller_client = Dea::CloudControllerClient.new(uuid, config['cc_url'], logger)
    end

    def setup_staging_responders
      @staging_responder = Dea::Responders::Staging.new(self, staging_task_registry, directory_server_v2, resource_manager, config)
      @http_staging_responder = Dea::Responders::HttpStaging.new(@staging_responder, cloud_controller_client)
    end

    def start_nats
      nats.start
    end

    def start_nats_staging_request_handler
      @nats_staging_responder = Dea::Responders::NatsStaging.new(nats, uuid, @staging_responder, config)

      @responders = [
        Dea::Responders::DeaLocator.new(nats, uuid, resource_manager, config, @local_dea_service),
        @nats_staging_responder,
      ].each(&:start)
    end

### /Start_Stuff

    def locator_responders
      return [] unless @responders
      @responders.select do |r|
        r.is_a?(Dea::Responders::DeaLocator)
      end
    end

    attr_reader :heartbeat_timer
    def setup_sweepers
      # reap orphaned dropletss and containers once on the startup
      reap_unreferenced_droplets
      reap_orphaned_containers

      # Heartbeats of instances we're managing
      hb_interval = config["intervals"]["heartbeat"] || DEFAULT_HEARTBEAT_INTERVAL
      @heartbeat_timer = EM.add_periodic_timer(hb_interval) { send_heartbeat }

      # Ensure we keep around only the most recent crash for short amount of time
      instance_registry.start_reaper

      # Remove unreferenced droplets
      EM.add_periodic_timer(DROPLET_REAPER_INTERVAL_SECS) do
        reap_unreferenced_droplets
      end

      EM.add_periodic_timer(CONTAINER_REAPER_INTERVAL_SECS) do
        reap_orphaned_containers
      end
    end

    def start_finish
      locator_responders.map(&:advertise)
      logger.info("Starting with #{instance_registry.size} instances")
      send_heartbeat()
    end

    def register_directory_server_v2
      @router_client.register_directory_server(
        directory_server_v2.port,
        directory_server_v2.external_hostname
      )
    end

    def start
      setup_signal_handlers

      download_buildpacks

      snapshot.load

      start_nats
      setup_sweepers
      start_nats_staging_request_handler
      setup_register_routes
      http_server.start
      directory_server_v2.start
      start_metrics

      start_finish

      logger.info("Dea started", uuid: uuid)
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

    def setup_register_routes
      register_routes
      interval = config["intervals"]["router_register_in_seconds"]

      @registration_timer = EM.add_periodic_timer(interval) do
        register_routes
      end
    end

    def handle_router_start
      register_routes
    end

    def register_routes
      instance_registry.each do |instance|
        next if !(instance.running? || instance.evacuating?) || instance.application_uris.empty?
        router_client.register_instance(instance)
      end

      register_directory_server_v2
    end

    def start_app(data)
      return if evac_handler.evacuating? || shutdown_handler.shutting_down?

      instance = instance_manager.create_instance(data)
      return unless instance

      instance.start
    end

    def handle_dea_stop(message)
      if message.data.size == 1 && message.data['droplet']
        staging_stop_msg = Dea::Nats::Message.new(
          message.nats,
          'staging.stop',
          {'app_id'  => message.data['droplet'].to_s},
          nil,
        )
        @nats_staging_responder.handle_stop(staging_stop_msg) if @nats_staging_responder
      end

      instance_registry.instances_filtered_by_message(message) do |instance|
        next if instance.resuming? || instance.stopped? || instance.crashed?

        instance.stop do |error|
          logger.warn("Failed stopping #{instance}: #{error}") if error
        end
      end
    end

    def handle_dea_update(message)
      app_id = message.data["droplet"].to_s
      uris = message.data["uris"]
      app_version = message.data["version"]

      updated = []
      instance_registry.instances_for_application(app_id).dup.each do |_, instance|
        next unless instance.running? || instance.evacuating?
        instance_updated = InstanceUriUpdater.new(instance, uris).update(router_client)
        if app_version != instance.application_version
          instance.application_version = app_version
          instance_registry.change_instance_id(instance)
          instance_updated = true
        end
        updated << instance_updated
      end

      if updated.reduce { |value, next_value| value && next_value }
        send_heartbeat
        snapshot.save
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

      hbs = Dea::Protocol::V1::HeartbeatResponse.generate(uuid, instances)
      hm9000.send_heartbeat(hbs)

      nil
    end

    def periodic_metrics_emit
      mem_required = config.minimum_staging_memory_mb
      disk_required = config.minimum_staging_disk_mb

      Dea::Loggregator.emit_value('uptime', uptime.to_i, 's')
      Dea::Loggregator.emit_value('remaining_memory', resource_manager.remaining_memory, 'mb')
      Dea::Loggregator.emit_value('remaining_disk', resource_manager.remaining_disk, 'mb')
      Dea::Loggregator.emit_value('available_memory_ratio', resource_manager.available_memory_ratio, 'P')
      Dea::Loggregator.emit_value('available_disk_ratio', resource_manager.available_disk_ratio, 'P')
      Dea::Loggregator.emit_value('instances', instance_registry.size, 'instances')
      Dea::Loggregator.emit_value('reservable_stagers', resource_manager.number_reservable(mem_required, disk_required), 'stagers')
      Dea::Loggregator.emit_value('avg_cpu_load', resource_manager.cpu_load_average, 'loadavg')
      Dea::Loggregator.emit_value('mem_used_bytes', resource_manager.memory_used_bytes, 'B')
      Dea::Loggregator.emit_value('mem_free_bytes', resource_manager.memory_free_bytes, 'B')

      instance_registry.emit_metrics_state
      instance_registry.emit_container_stats
    end

    def download_buildpacks
      return unless config['staging'] && config['staging']['enabled']

      buildpacks_url = URI::join(config['cc_url'], '/internal/buildpacks')
      http = EM::HttpRequest.new(buildpacks_url, :connect_timeout => 5).get
      http.errback do
        logger.error("buildpacks-request.error", error: http.error)
      end

      http.callback do
        begin
          http_status = http.response_header.status
          if http_status == 200
            workspace = StagingTaskWorkspace.new(config['base_dir'], nil)
            Fiber.new do
              AdminBuildpackDownloader.new(BuildpacksMessage.new(MultiJson.load(http.response)).buildpacks, workspace.admin_buildpacks_dir).download
            end.resume
            logger.info('buildpacks-downloaded.success')
          else
            logger.warn('buildpacks-request.failed', status: http_status)
          end
        rescue => e
          logger.error("em-download.failed", error: e, backtrace: e.backtrace)
        end
      end
    end

    def stage_app_request(data)
      return if !@http_staging_responder
      @http_staging_responder.handle(data)
    end

    private

    def logger
      @logger ||= self.class.logger
    end
  end
end
