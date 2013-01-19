# coding: UTF-8

require "set"

require "steno"
require "steno/config"
require "steno/core_ext"

require "thin"

require "vcap/common"
require "vcap/component"

require "dea/config"
require "dea/directory_server"
require "dea/directory_server_v2"
require "dea/droplet_registry"
require "dea/file_api"
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
    DROPLET_REAPER_INTERVAL_SECS   = 10

    DISCOVER_DELAY_MS_PER_INSTANCE = 10
    DISCOVER_DELAY_MS_MEM          = 100
    DISCOVER_DELAY_MS_MAX          = 250

    EXIT_REASON_STOPPED            = "STOPPED"
    EXIT_REASON_CRASHED            = "CRASHED"
    EXIT_REASON_SHUTDOWN           = "DEA_SHUTDOWN"
    EXIT_REASON_EVACUATION         = "DEA_EVACUATION"

    SIGNALS_OF_INTEREST            = %W(TERM INT QUIT USR1 USR2)

    attr_reader :config
    attr_reader :nats
    attr_reader :uuid

    def initialize(config = {})
      @config = Config.new(config)
    end

    def local_ip
      @local_ip ||= VCAP.local_ip(config["local_route"])
    end

    def validate_config
      config.validate
    end

    def setup
      validate_config

      setup_logging
      setup_runtimes
      setup_droplet_registry
      setup_resource_manager
      setup_instance_registry
      setup_directory_server
      setup_directory_server_v2
      setup_file_api
      setup_signal_handlers
      setup_directories
      setup_pid_file
      setup_sweepers
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
      runtimes = Hash[config["runtimes"].map do |name|
        [name, nil]
      end]

      if runtimes.empty?
        logger.fatal "No runtimes"
        exit 1
      end

      @runtimes = runtimes

      nil
    end

    def runtime(name, options = {})
      if runtimes.has_key?(name)
        if runtimes[name].nil?
          runtime = Runtime.new(options)

          # Only cache runtime if it validates
          begin
            runtime.validate
          rescue Runtime::BaseError => err
            logger.warn err.to_s
          else
            runtimes[name] = runtime
          end
        end

        runtimes[name]
      end
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
      @instance_registry = Dea::InstanceRegistry.new(config)
    end

    attr_reader :router_client

    def setup_router_client
      @router_client = Dea::RouterClient.new(self)
    end

    def setup_signal_handlers
      @old_signal_handlers = {}

      SIGNALS_OF_INTEREST.each do |signal|
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

      @old_signal_handlers = {}
    end

    def with_signal_handlers
      begin
        setup_signal_handlers
        yield
      ensure
        teardown_signal_handlers
      end
    end

    def ignore_signals
      SIGNALS_OF_INTEREST.each do |signal|
        ::Kernel.trap(signal) do
          logger.warn("Caught SIG#{signal}, ignoring.")
        end
      end
    end

    def trap_term
      shutdown
    end

    def trap_int
      shutdown
    end

    def trap_quit
      shutdown
    end

    def trap_usr1
      exit
    end

    def trap_usr2
      evacuate
    end

    def setup_directories
      %W(db droplets instances tmp).each do |dir|
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
        logger.error "Cannot create pid file at #{path} (#{err})"
        raise
      end
    end

    def setup_sweepers
      # Heartbeats of instances we're managing
      hb_interval = config["intervals"]["heartbeat"] || DEFAULT_HEARTBEAT_INTERVAL
      @heartbeat_timer = EM.add_periodic_timer(hb_interval) { send_heartbeat(instance_registry.to_a) }

      # Notifications for CloudControllers looking to place droplets
      advertise_interval = config["intervals"]["advertise"] || DEFAULT_ADVERTISE_INTERVAL
      @advertise_timer = EM.add_periodic_timer(advertise_interval) { send_advertise }

      # Ensure we keep around only the most recent crash for short amount of time
      instance_registry.start_reaper

      # Remove unreferenced droplets
      EM.add_periodic_timer(DROPLET_REAPER_INTERVAL_SECS) do
        reap_unreferenced_droplets
      end
    end

    def stop_sweepers
      # Only need to stop nats-talking sweepers
      # No need to check the timers, EM code is robust enough
      EM.cancel_timer(@heartbeat_timer)
      EM.cancel_timer(@advertise_timer)
    end

    attr_reader :directory_server

    def setup_directory_server
      v1_port = config["directory_server"]["v1_port"]
      @directory_server = Dea::DirectoryServer.new(local_ip,
                                                   v1_port,
                                                   instance_registry)
    end

    attr_reader :directory_server_v2

    def setup_directory_server_v2
      v2_port = config["directory_server"]["v2_port"]
      @directory_server_v2 = Dea::DirectoryServerV2.new(config["domain"],
                                                        v2_port)
    end

    def setup_file_api
      Dea::FileApi.configure(instance_registry,
                             VCAP.secure_uuid,
                             60 * 60)

      Thin::Logging.silent = true
      file_api_port = config["directory_server"]["file_api_port"]
      @file_api_server = Thin::Server.new("127.0.0.1",
                                          file_api_port,
                                          Dea::FileApi)
    end

    def start_directory_server
      @directory_server.start
    end

    def start_file_api_server
      @file_api_server.start
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
        :nats     => self.nats.client,
        :port     => config["status"]["port"],
        :user     => config["status"]["user"],
        :password => config["status"]["password"])

      @uuid = VCAP::Component.uuid
    end

    def start_finish
      nats.publish("dea.start", Dea::Protocol::V1::HelloMessage.generate(self))

      send_advertise
    end

    def register_directory_server_v2
      @router_client.register_directory_server(local_ip,
                                               directory_server_v2.port,
                                               directory_server_v2.external_hostname)
    end

    def unregister_directory_server_v2
      @router_client.unregister_directory_server(local_ip,
                                                 directory_server_v2.port,
                                                 directory_server_v2.external_hostname)
    end

    def start
      load_snapshot

      start_component
      start_nats
      start_directory_server
      register_directory_server_v2
      start_file_api_server

      unless instance_registry.empty?
        logger.info("Loaded #{instance_registry.size} instances from snapshot")

        # Wait a bit to give instances time to re-link, and figure out their state
        ::EM.add_timer(1.0) do
          send_heartbeat(instance_registry.to_a)
          start_finish
        end
      else
        start_finish
      end
    end

    def snapshot_path
      File.join(config["base_dir"], "db", "instances.json")
    end

    def save_snapshot
      start = Time.now

      instances = instance_registry.select do |i|
        [
          Dea::Instance::State::RUNNING,
          Dea::Instance::State::CRASHED,
        ].include?(i.state)
      end

      snapshot = {
        "time"      => start.to_f,
        "instances" => instances.map(&:attributes),
      }

      file = Tempfile.new("instances", File.join(config["base_dir"], "tmp"))
      file.write(::Yajl::Encoder.encode(snapshot, :pretty => true))
      file.close

      FileUtils.mv(file.path, snapshot_path)

      logger.debug("Saving snapshot took: %.3fs" % [Time.now - start])
    end

    def load_snapshot
      return unless File.exist?(snapshot_path)

      start = Time.now

      snapshot = ::Yajl::Parser.parse(File.read(snapshot_path))
      snapshot ||= {}

      if snapshot["instances"]
        snapshot["instances"].each do |attributes|
          instance_state = attributes.delete("state")
          instance = create_instance(attributes)

          # Ignore instance if it doesn't validate
          begin
            instance.validate
          rescue => error
            logger.warn("Error validating instance: #{error.message}")
            next
          end

          # Enter instance state via "RESUMING" to trigger the right transitions
          instance.state = Instance::State::RESUMING
          instance.state = instance_state
        end

        logger.debug("Loading snapshot took: %.3fs" % [Time.now - start])
      end
    end

    def reap_unreferenced_droplets
      refd_shas = Set.new(instance_registry.map(&:droplet_sha1))
      all_shas  = Set.new(droplet_registry.keys)

      (all_shas - refd_shas).each do |unused_sha|
        logger.debug("Removing droplet for sha=#{unused_sha}")

        droplet = droplet_registry.delete(unused_sha)
        droplet.destroy
      end
    end

    def create_instance(attributes)
      instance = Instance.new(self, Instance.translate_attributes(attributes))
      instance.setup

      instance.on(Instance::Transition.new(:resuming, :running)) do
        instance_registry.register(instance)
      end

      instance.on(Instance::Transition.new(:resuming, :crashed)) do
        instance_registry.register(instance)
      end

      instance.on(Instance::Transition.new(:born, :starting)) do
        instance_registry.register(instance)
      end

      instance.on(Instance::Transition.new(:starting, :crashed)) do
        send_exited_message(instance, EXIT_REASON_CRASHED)
      end

      instance.on(Instance::Transition.new(:starting, :running)) do
        # Notify others immediately
        send_heartbeat([instance])

        # Register with router
        router_client.register_instance(instance)
      end

      instance.on(Instance::Transition.new(:running, :crashed)) do
        router_client.unregister_instance(instance)
        send_exited_message(instance, EXIT_REASON_CRASHED)
      end

      instance.on(Instance::Transition.new(:running, :stopping)) do
        router_client.unregister_instance(instance)

        # This is a little wonky but ensures that we don't send an exited
        # message twice. During evacuation, an exit message is sent for each
        # running app, the evacuation interval is allowed to pass, and the app
        # is finally stopped.  This allows the app to be started on another DEA
        # and begin serving traffic before we stop it here.
        if !evacuating?
          reason = nil

          if shutting_down?
            reason = EXIT_REASON_SHUTDOWN
          else
            reason = EXIT_REASON_STOPPED
          end

          send_exited_message(instance, reason)
        end
      end

      instance.on(Instance::Transition.new(:starting, :running)) do
        save_snapshot
      end

      instance.on(Instance::Transition.new(:running, :stopping)) do
        save_snapshot
      end

      instance.on(Instance::Transition.new(:running, :crashed)) do
        save_snapshot
      end

      instance.on(Instance::Transition.new(:stopping, :stopped)) do
        @instance_registry.unregister(instance)
        EM.next_tick { instance.destroy }
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

      register_directory_server_v2
    end

    def handle_dea_status(message)
      message.respond(Dea::Protocol::V1::DeaStatusResponse.generate(self))
    end

    def handle_dea_directed_start(message)
      instance = create_instance(message.data)

      if config.only_production_apps? && !instance.production_app?
        logger.info("Ignoring instance for non-production app: #{instance}")
        return
      end

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

        instance.stop do |error|
          logger.warn("Failed stopping #{instance}: #{error}") if error
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

      delay = calculate_discover_delay(message.data["droplet"].to_s)

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
      app_id = message.data["droplet"].to_s
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
      instances_filtered_by_message(message) do |instance|
        response = Dea::Protocol::V1::FindDropletResponse.generate(self,
                                                                   instance,
                                                                   message.data)
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

    def evacuating?
      @evacuation_processed == true
    end

    def evacuate
      if @evacuation_processed
        logger.info("Evacuation already processed, doing nothing.")
        return
      else
        logger.info("Evacuating apps")
        @evacuation_processed = true
      end

      ignore_signals
      stop_sweepers

      instance_registry.each do |instance|
        next unless instance.running? || instance.starting?

        send_exited_message(instance, EXIT_REASON_EVACUATION)
      end

      EM.add_timer(config["evacuation_delay_secs"]) { shutdown }
    end

    def shutting_down?
      @shutdown_processed == true
    end

    def shutdown
      if @shutdown_processed
        logger.info("Shutdown already processed, doing nothing.")
        return
      else
        logger.info("Shutting down")
        @shutdown_processed = true
      end

      ignore_signals

      nats.stop

      unregister_directory_server_v2

      pending_stops = Set.new([])
      on_pending_empty = proc do
        logger.info("All instances stopped, exiting.")
        nats.client.flush
        terminate
      end

      instance_registry.each do |instance|
        pending_stops.add(instance)

        instance.stop do |error|
          pending_stops.delete(instance)

          if error
            logger.warn("#{instance} failed to stop: #{error}")
          else
            logger.debug("#{instance} exited")
          end

          if pending_stops.empty?
            on_pending_empty.call
          end
        end
      end

      if pending_stops.empty?
        on_pending_empty.call
      end
    end

    # So we can test shutdown()
    def terminate
      exit
    end

    def send_exited_message(instance, reason)
      msg = Dea::Protocol::V1::ExitMessage.generate(instance, reason)
      nats.publish("droplet.exited", msg)

      nil
    end

    def send_heartbeat(instances)
      instances = instances.select do |instance|
        match = false
        match ||= instance.starting?
        match ||= instance.running?
        match ||= instance.crashed?
        match
      end

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
      app_id = message.data["droplet"].to_s

      if app_id
        logger.debug2("Filter message for app_id: %s" % app_id, :app_id => app_id)
      else
        logger.warn("Filter message missing app_id")
        return
      end

      instances = instance_registry.instances_for_application(app_id)
      if instances.empty?
        logger.debug2("No instances found for app_id: %s" % app_id, :app_id => app_id)
        return
      end

      set_or_nil = lambda { |h, k| h.has_key?(k) ? Set.new(h[k]) : nil }

      # Optional search filters
      version        = message.data["version"]
      instance_ids   = set_or_nil.call(message.data, "instances")
      instance_ids ||= set_or_nil.call(message.data, "instance_ids")
      indices        = set_or_nil.call(message.data, "indices")
      states         = set_or_nil.call(message.data, "states")
      states         = states.map { |e| Dea::Instance::State.from_external(e) } unless states.nil?

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

    private

    def logger
      @logger ||= self.class.logger
    end
  end
end
