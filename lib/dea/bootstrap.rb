# coding: UTF-8

require "steno"
require "steno/config"
require "steno/core_ext"
require "vcap/common"
require "vcap/component"

require "dea/config"
require "dea/droplet_registry"
require "dea/instance_registry"
require "dea/nats"
require "dea/protocol"
require "dea/router_client"

module Dea
  class Bootstrap
    DEFAULT_HEARTBEAT_INTERVAL = 10 # In secs
    DEFAULT_ADVERTISE_INTERVAL = 5

    attr_reader :config
    attr_reader :nats
    attr_reader :uuid

    def initialize(config = {})
      @config = {"intervals" => {}}.merge(config)
    end

    def local_ip
      @local_ip ||= VCAP.local_ip(config["local_route"])
    end

    def setup
      Config.schema.validate(config)

      setup_logging
      setup_runtimes
      setup_droplet_registry
      setup_instance_registry
      setup_signal_handlers
      setup_directories
      setup_pid_file
      setup_sweepers
      setup_nats
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
    end

    def trap_int
    end

    def trap_quit
    end

    def trap_usr1
    end

    def trap_usr2
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
      EM.add_periodic_timer(hb_interval) { send_heartbeats }

      # Notifications for CloudControllers looking to place droplets
      advertise_interval = config["intervals"]["advertise"] || DEFAULT_ADVERTISE_INTERVAL
      EM.add_periodic_timer(advertise_interval) { send_advertise }
    end

    def setup_nats
      @nats = Dea::Nats.new(self, config)
    end

    def handle_health_manager_start(message)
      send_heartbeats
    end

    def handle_router_start(message)
      instance_registry.each do |instance|
        next if !instance.running? || instance.application_uris.empty?
        router_client.register_instance(instance)
      end
    end

    def handle_dea_status(message)
    end

    def handle_dea_directed_start(message)
    end

    def handle_dea_locate(message)
      send_advertise
    end

    def handle_dea_stop(message)
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
      app_id  = message.data["droplet"]

      if app_id
        logger.debug("Find droplet request for app #{app_id}", :app_id => app_id)
      else
        logger.warn("Find droplet request missing app_id")
        return
      end

      instances = instance_registry.instances_for_application(app_id)
      if instances.empty?
        logger.info("No instances found for app #{app_id}", :app_id => app_id)
        return
      end

      set_or_nil = lambda { |h, k| h.has_key?(k) ? Set.new(h[k]) : nil }

      # Optional search filters
      version       = message.data["version"]
      instance_ids  = set_or_nil.call(message.data, "instances")
      indices       = set_or_nil.call(message.data, "indices")
      states        = set_or_nil.call(message.data, "states")
      include_stats = !!message.data["include_stats"]

      instances.each do |_, instance|
        matched = true

        matched &&= (instance.application_version == version)   unless version.nil?
        matched &&= instance_ids.include?(instance.instance_id) unless instance_ids.nil?
        matched &&= indices.include?(instance.instance_index)   unless indices.nil?
        matched &&= states.include?(instance.state)             unless states.nil?

        if matched
          response = Dea::Protocol::V1::FindDropletResponse.generate(self,
                                                                     instance,
                                                                     include_stats)
          message.respond(response)
        end
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

    def send_heartbeats
      return if @instance_registry.empty?

      hbs = Dea::Protocol::V1::HeartbeatResponse.generate(self, instance_registry.to_a)
      @nats.publish("dea.heartbeat", hbs)

      nil
    end

    def send_advertise
      # TODO: Return if resources are exhausted
      msg = Dea::Protocol::V1::AdvertiseMessage.generate(self)
      @nats.publish("dea.advertise", msg)
    end

    private

    def logger
      @logger ||= self.class.logger
    end
  end
end
