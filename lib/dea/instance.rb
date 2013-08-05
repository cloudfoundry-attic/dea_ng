# coding: UTF-8

require "membrane"
require "steno"
require "steno/core_ext"
require "vcap/common"
require "yaml"

require "dea/container"
require "dea/env"
require "dea/health_check/port_open"
require "dea/health_check/state_file_ready"
require "dea/promise"
require "dea/stat_collector"
require "dea/task"
require "dea/utils/event_emitter"
require "dea/starting/startup_script_generator"

module Dea
  class Instance < Task
    include EventEmitter

    STAT_COLLECTION_INTERVAL_SECS = 10

    BIND_MOUNT_MODE_MAP = {
      "ro" =>  ::Warden::Protocol::CreateRequest::BindMount::Mode::RO,
      "rw" =>  ::Warden::Protocol::CreateRequest::BindMount::Mode::RW,
    }

    class State
      BORN     = "BORN"
      STARTING = "STARTING"
      RUNNING  = "RUNNING"
      STOPPING = "STOPPING"
      STOPPED  = "STOPPED"
      CRASHED  = "CRASHED"
      DELETED  = "DELETED"
      RESUMING = "RESUMING"

      def self.from_external(state)
        case state.upcase
        when "BORN"
          BORN
        when "STARTING"
          STARTING
        when "RUNNING"
          RUNNING
        when "STOPPING"
          STOPPING
        when "STOPPED"
          STOPPED
        when "CRASHED"
          CRASHED
        when "DELETED"
          DELETED
        when "RESUMING"
          RESUMING
        else
          raise "Unknown state: #{state}"
        end
      end

      def self.to_external(state)
        case state
        when Dea::Instance::State::BORN
          "BORN"
        when Dea::Instance::State::STARTING
          "STARTING"
        when Dea::Instance::State::RUNNING
          "RUNNING"
        when Dea::Instance::State::STOPPING
          "STOPPING"
        when Dea::Instance::State::STOPPED
          "STOPPED"
        when Dea::Instance::State::CRASHED
          "CRASHED"
        when Dea::Instance::State::DELETED
          "DELETED"
        when Dea::Instance::State::RESUMING
          "RESUMING"
        else
          raise "Unknown state: #{state}"
        end
      end
    end

    class Transition < Struct.new(:from, :to)
      def initialize(*args)
        super(*args.map(&:to_s).map(&:downcase))
      end
    end

    class TransitionError < BaseError
      attr_reader :from
      attr_reader :to

      def initialize(from, to = nil)
        @from = from
        @to = to
      end

      def message
        parts = []
        parts << "Cannot transition from %s" % [from.inspect]

        if to
          parts << "to %s" % [to.inspect]
        end

        parts.join(" ")
      end
    end

    def self.translate_attributes(attributes)
      attributes = attributes.dup

      transfer_attr_with_existance_check(attributes, "instance_index", "index")
      transfer_attr_with_existance_check(attributes, "application_version", "version")
      transfer_attr_with_existance_check(attributes, "application_name", "name")
      transfer_attr_with_existance_check(attributes, "application_uris", "uris")

      attributes["application_id"] ||= attributes.delete("droplet").to_s if attributes["droplet"]
      attributes["tags"] ||= attributes.delete("tags") { |_| {} } if attributes["tags"]
      attributes["droplet_sha1"] ||= attributes.delete("sha1")
      attributes["droplet_uri"] ||= attributes.delete("executableUri")

      # Translate environment to dictionary (it is passed as Array with VAR=VAL)
      env = attributes.delete("env") || []
      attributes["environment"] ||= Hash[env.map do |e|
        pair = e.split("=", 2)
        pair[0] = pair[0].to_s
        pair[1] = pair[1].to_s
        pair
      end]

      attributes
    end

    def self.transfer_attr_with_existance_check(attr, new_key, old_key)
      attr[new_key] ||= attr.delete(old_key) if attr[old_key]
    end

    def self.limits_schema
      Membrane::SchemaParser.parse do
        {
          "mem"  => Fixnum,
          "disk" => Fixnum,
          "fds"  => Fixnum,
        }
      end
    end

    def self.service_schema
      Membrane::SchemaParser.parse do
        {
          "name"        => String,
          "label"        => String,
          "credentials" => any,

          # Deprecated fields
          optional("plan")        => String,
          optional("vendor")      => String,
          optional("version")     => String,
          optional("type")        => String,
          optional("tags")        => [String],
          optional("plan_option") => enum(String, nil),
        }
      end
    end

    def self.schema
      limits_schema = self.limits_schema
      service_schema = self.service_schema

      Membrane::SchemaParser.parse do
        {
          # Static attributes (coming from cloud controller):
          "cc_partition"        => String,

          "instance_id"         => String,
          "instance_index"      => Integer,

          "application_id"      => String,
          "application_version" => String,
          "application_name"    => String,
          "application_uris"    => [String],

          "droplet_sha1"        => enum(nil, String),
          "droplet_uri"         => enum(nil, String),

          optional("tags")                 => dict(String, any),
          optional("runtime_name")         => String,
          optional("runtime_info")         => dict(String, any),
          optional("framework_name")       => String,

          # TODO: use proper schema
          "limits"              => limits_schema,
          "environment"         => dict(String, String),
          "services"            => [service_schema],
          optional("flapping")  => bool,

          optional("debug")     => enum(nil, String),
          optional("console")   => enum(nil, bool),

          # private_instance_id is internal id that represents the instance,
          # which is generated by DEA itself. Currently, we broadcast it to
          # all routers. Routers use that as sticky session of the instance.
          "private_instance_id" => String,
        }
      end
    end

    # Define an accessor for every attribute with a schema
    self.schema.schemas.each do |key, _|
      define_method(key) do
        attributes[key]
      end
    end

    # Accessors for different types of host/container ports
    [nil, "debug", "console"].each do |type|
      ["host", "container"].each do |side|
        key = ["instance", type, side, "port"].compact.join("_")
        define_method(key) do
          attributes[key]
        end
      end
    end

    def self.define_state_methods(state)
      state_predicate = "#{state.to_s.downcase}?"
      define_method(state_predicate) do
        self.state == state
      end

      state_time = "state_#{state.to_s.downcase}_timestamp"
      define_method(state_time) do
        attributes[state_time]
      end
    end

    # Define predicate methods for querying state
    State.constants.each do |state|
      define_state_methods(State.const_get(state))
    end

    attr_reader :bootstrap
    attr_reader :attributes
    attr_accessor :exit_status
    attr_accessor :exit_description

    def initialize(bootstrap, attributes)
      super(bootstrap.config)
      @bootstrap = bootstrap

      @raw_attributes = attributes.dup
      @attributes = Instance.translate_attributes(@raw_attributes)
      @attributes["application_uris"] ||= []

      # Generate unique ID
      @attributes["instance_id"] ||= VCAP.secure_uuid

      # Contatenate 2 UUIDs to genreate a 32 chars long private_instance_id
      @attributes["private_instance_id"] ||= VCAP.secure_uuid + VCAP.secure_uuid

      self.state = State::BORN

      @exit_status           = -1
      @exit_description      = ""
    end

    def setup
      setup_stat_collector
      setup_link
      setup_crash_handler
    end

    # TODO: Fill in once start is hooked up
    def flapping?
      false
    end

    def memory_limit_in_bytes
      limits["mem"].to_i * 1024 * 1024
    end

    def disk_limit_in_bytes
      limits["disk"].to_i * 1024 * 1024
    end

    def file_descriptor_limit
      limits["fds"].to_i
    end

    def instance_path_available?
      state == State::RUNNING || state == State::CRASHED
    end

    def consuming_memory?
      case state
      when State::BORN, State::STARTING, State::RUNNING, State::STOPPING
        true
      else
        false
      end
    end

    def consuming_disk?
      case state
      when State::BORN, State::STARTING, State::RUNNING, State::STOPPING,
           State::CRASHED
        true
      else
        false
      end
    end

    def instance_path
      attributes["instance_path"] ||=
        begin
          if !instance_path_available? || attributes["warden_container_path"].nil?
            raise "Instance path unavailable"
          end

          File.expand_path(container_relative_path(attributes["warden_container_path"]))
        end
    end

    def paths_to_bind
      [droplet.droplet_dirname]
    end

    def validate
      self.class.schema.validate(attributes)
    end

    def state
      attributes["state"]
    end

    def state=(state)
      transition = Transition.new(attributes["state"], state)

      attributes["state"] = state
      attributes["state_timestamp"] = Time.now.to_f

      state_time = "state_#{state.to_s.downcase}_timestamp"
      attributes[state_time] = Time.now.to_f

      emit(transition)
    end

    def state_timestamp
      attributes["state_timestamp"]
    end

    def droplet
      bootstrap.droplet_registry[droplet_sha1]
    end

    def application_uris=(uris)
      attributes["application_uris"] = uris
      nil
    end

    def to_s
      "Instance(id=%s, idx=%s, app_id=%s)" % [instance_id.slice(0, 4),
                                             instance_index, application_id]
    end

    def promise_state(from, to = nil)
      Promise.new do |p|
        if !Array(from).include?(state)
          p.fail(TransitionError.new(state, to))
        else
          if to
            self.state = to
          end

          p.deliver
        end
      end
    end

    def promise_droplet_download
      Promise.new do |p|
        droplet.download(droplet_uri) do |error|
          if error
            p.fail(error)
          else
            p.deliver
          end
        end
      end
    end

    def promise_setup_network
      Promise.new do |p|
        response = get_new_warden_net_in
        attributes["instance_host_port"]      = response.host_port
        attributes["instance_container_port"] = response.container_port

        response = get_new_warden_net_in
        attributes["instance_console_host_port"]      = response.host_port
        attributes["instance_console_container_port"] = response.container_port

        if attributes["debug"]
          response = get_new_warden_net_in
          attributes["instance_debug_host_port"]      = response.host_port
          attributes["instance_debug_container_port"] = response.container_port
        end

        p.deliver
      end
    end

    def promise_setup_environment
      Promise.new do |p|
        script = "cd / && mkdir -p home/vcap/app && chown vcap:vcap home/vcap/app && ln -s home/vcap/app /app"
        promise_warden_run(:app, script, true).resolve

        p.deliver
      end
    end

    def promise_extract_droplet
      Promise.new do |p|
        script = "cd /home/vcap/ && tar zxf #{droplet.droplet_path}"

        promise_warden_run(:app, script).resolve

        p.deliver
      end
    end

    def promise_start
      Promise.new do |p|
        env = Env.new(@raw_attributes, self)

        start_script =
          if staged_info
             Dea::StartupScriptGenerator.new(
               staged_info.fetch("start_command"),
               env.exported_user_environment_variables,
               env.exported_system_environment_variables,
               staged_info.fetch("detected_buildpack")
             ).generate
           else
             env.exported_environment_variables + "./startup;\nexit"
           end

        log(:info, "foo.bal", staged_info: staged_info, start_script: start_script)

        request = ::Warden::Protocol::SpawnRequest.new
        request.handle = attributes["warden_handle"]
        request.script = start_script

        request.rlimits = ::Warden::Protocol::ResourceLimits.new
        request.rlimits.nofile = self.file_descriptor_limit
        request.rlimits.nproc = 512

        response = promise_warden_call(:app, request).resolve

        attributes["warden_job_id"] = response.job_id

        p.deliver
      end
    end

    def promise_exec_hook_script(key)
      Promise.new do |p|
        if bootstrap.config['hooks'] && bootstrap.config['hooks'][key]
          script_path = bootstrap.config['hooks'][key]
          if File.exist?(script_path)
            script = []
            script << "umask 077"
            script << Env.new(@raw_attributes, self).exported_environment_variables
            script << File.read(script_path)
            script << "exit"
            promise_warden_run(:app, script.join("\n")).resolve
          else
            log(:warn, "droplet.hook-script.missing", :hook => key, :script_path => script_path)
          end
        end
        p.deliver
      end
    end

    def start(&callback)
      p = Promise.new do
        log(:info, "droplet.starting")

        promise_state(State::BORN, State::STARTING).resolve

        # Concurrently download droplet and setup container
        [
          promise_droplet,
          promise_container
        ].each(&:run).each(&:resolve)

        [
          promise_extract_droplet,
          promise_exec_hook_script('before_start'),
          promise_start
        ].each(&:resolve)

        on(Transition.new(:starting, :crashed)) do
          cancel_health_check
        end

        # Fire off link so that the health check can be cancelled when the
        # instance crashes before the health check completes.
        link

        if promise_health_check.resolve
          promise_state(State::STARTING, State::RUNNING).resolve
          log(:info, "droplet.healthy")
          promise_exec_hook_script('after_start').resolve
        else
          log(:warn, "droplet.unhealthy")
          p.fail("App instance failed health check")
        end

        p.deliver
      end

      resolve(p, "start instance") do |error, _|
        if error
          # An error occured while starting, mark as crashed
          self.exit_description = error.message
          self.state = State::CRASHED
        end

        callback.call(error) unless callback.nil?
      end
    end

    def promise_container
      Promise.new do |p|
        promise_create_container.resolve
        promise_setup_network.resolve
        promise_limit_disk.resolve
        promise_limit_memory.resolve
        promise_setup_environment.resolve

        p.deliver
      end
    end

    def promise_droplet
      Promise.new do |p|
        if !droplet.droplet_exist?
          log(:info, "droplet.download.starting")
          start = Time.now
          promise_droplet_download.resolve
          log(:info, "droplet.download.finished", :took => Time.now - start)
        else
          log(:info, "droplet.download.skipped")
        end

        p.deliver
      end
    end

    def stop(&callback)
      p = Promise.new do
        log(:info, "droplet.stopping")

        promise_exec_hook_script('before_stop').resolve

        promise_state(State::RUNNING, State::STOPPING).resolve

        promise_exec_hook_script('after_stop').resolve

        promise_stop.resolve

        promise_state(State::STOPPING, State::STOPPED).resolve

        p.deliver
      end

      resolve(p, "stop instance") do |error, _|
        callback.call(error) unless callback.nil?
      end
    end

    def promise_copy_out
      Promise.new do |p|
        new_instance_path = File.join(config.crashes_path, instance_id)
        new_instance_path = File.expand_path(new_instance_path)
        copy_out_request("/home/vcap/", new_instance_path)

        attributes["instance_path"] = new_instance_path

        p.deliver
      end
    end

    def setup_crash_handler
      # Resuming to crashed state
      on(Transition.new(:resuming, :crashed)) do
        crash_handler
      end

      # On crash
      on(Transition.new(:starting, :crashed)) do
        crash_handler
      end

      # On crash
      on(Transition.new(:running, :crashed)) do
        crash_handler
      end
    end

    def promise_crash_handler
      Promise.new do |p|
        if attributes["warden_handle"]
          promise_copy_out.resolve
          promise_destroy.resolve

          close_warden_connections
        end

        p.deliver
      end
    end

    def crash_handler(&callback)
      Promise.resolve(promise_crash_handler) do |error, _|
        if error
          log(
            :warn, "droplet.crash-handler.error",
            :error => error, :backtrace => error.backtrace)
        end

        callback.call(error) unless callback.nil?
      end
    end

    def setup_stat_collector
      on(Transition.new(:resuming, :running)) do
        stat_collector.start
      end

      on(Transition.new(:starting, :running)) do
        stat_collector.start
      end

      on(Transition.new(:running, :stopping)) do
        stat_collector.stop
      end

      on(Transition.new(:running, :crashed)) do
        stat_collector.stop
      end
    end

    def setup_link
      # Resuming to running state
      on(Transition.new(:resuming, :running)) do
        link
      end
    end

    def promise_link
      Promise.new do |p|
        request = ::Warden::Protocol::LinkRequest.new
        request.handle = attributes["warden_handle"]
        request.job_id = attributes["warden_job_id"]
        response = promise_warden_call_with_retry(:link, request).resolve

        log(:info, "droplet.warden.link.completed", :exit_status => response.exit_status)

        p.deliver(response)
      end
    end

    def link(&callback)
      Promise.resolve(promise_link) do |error, link_response|
        if error
          self.exit_status = -1
          self.exit_description = "unknown"
        else
          self.exit_status = link_response.exit_status
          self.exit_description = determine_exit_description(link_response)
        end

        case self.state
        when State::STARTING
          self.state = State::CRASHED
        when State::RUNNING
          uptime = Time.now - attributes["state_running_timestamp"]
          log(:info, "droplet.instance.uptime", :uptime => uptime)

          self.state = State::CRASHED
        else
          # Linking likely completed because of stop
        end

        callback.call(error) unless callback.nil?
      end
    end

    def promise_read_instance_manifest(container_path)
      Promise.new do |p|
        if container_path.nil?
          p.deliver({})
          next
        end

        manifest_path = container_relative_path(container_path, "droplet.yaml")
        if File.exist?(manifest_path)
          manifest = YAML.load_file(manifest_path)
          p.deliver(manifest)
        else
          p.deliver({})
        end
      end
    end

    def promise_port_open(port)
      Promise.new do |p|
        host = bootstrap.local_ip

        log(:debug, "droplet.healthcheck.port", :host => host, :port => port)

        @health_check = Dea::HealthCheck::PortOpen.new(host, port) do |hc|
          hc.callback { p.deliver(true) }

          hc.errback  { p.deliver(false) }

          if attributes["debug"] != "suspend"
            hc.timeout(60)
          end
        end
      end
    end

    def promise_state_file_ready(path)
      Promise.new do |p|
        log(:debug, "droplet.healthcheck.file", :path => path)

        @health_check = Dea::HealthCheck::StateFileReady.new(path) do |hc|
          hc.callback { p.deliver(true) }

          hc.errback { p.deliver(false) }

          if attributes["debug"] != "suspend"
            hc.timeout(60 * 5)
          end
        end
      end
    end

    def cancel_health_check
      if @health_check
        @health_check.fail
        @health_check = nil
      end
    end

    def promise_health_check
      Promise.new do |p|
        begin
          logger.debug "droplet.health-check.get-container-info"
          info = container.info
          logger.debug "droplet.health-check.container-info-ok"
        rescue => e
          logger.error "droplet.health-check.container-info-failed",
            :error => e, :backtrace => e.backtrace

          p.deliver(false)
        else
          attributes["warden_container_path"] = info.container_path
          attributes["warden_host_ip"] = info.host_ip

          manifest = promise_read_instance_manifest(info.container_path).resolve

          if manifest && manifest["state_file"]
            manifest_path = container_relative_path(info.container_path, manifest["state_file"])
            p.deliver(promise_state_file_ready(manifest_path).resolve)
          elsif !application_uris.empty?
            p.deliver(promise_port_open(instance_host_port).resolve)
          else
            p.deliver(true)
          end
        end
      end
    end

    def used_memory_in_bytes
      stat_collector.used_memory_in_bytes
    end

    def used_disk_in_bytes
      stat_collector.used_disk_in_bytes
    end

    def computed_pcpu
      stat_collector.computed_pcpu
    end

    def container
      @container ||= Dea::Container.new(@attributes["warden_handle"], config["warden_socket"])
    end

    def stat_collector
      @stat_collector ||= StatCollector.new(container)
    end

    def staged_info
      @staged_info ||= begin
        destination_dir = Dir.mktmpdir
        staging_file_name = "staging_info.yml"
        copied_file_name = "#{destination_dir}/#{staging_file_name}"

        copy_out_request("/home/vcap/#{staging_file_name}", destination_dir)

        YAML.load_file(copied_file_name) if File.exists?(copied_file_name)
      end
    end

    private

    def get_new_warden_net_in
      request = ::Warden::Protocol::NetInRequest.new
      request.handle = @attributes["warden_handle"]
      promise_warden_call(:app, request).resolve
    end

    def determine_exit_description(link_response)
      info = link_response.info
      return "cannot be determined" unless info

      if info.events && info.events.include?("oom")
        return "out of memory"
      end

      "app instance exited"
    end

    def container_relative_path(root, *parts)
      # This can be removed once warden's wsh branch is merged to master
      if File.directory?(File.join(root, "rootfs"))
        return File.join(root, "rootfs", "home", "vcap", *parts)
      end

      # New path
      File.join(root, "tmp", "rootfs", "home", "vcap", *parts)
    end

    def logger
      tags = {
        "instance_id"         => instance_id,
        "instance_index"      => instance_index,
        "application_id"      => application_id,
        "application_version" => application_version,
        "application_name"    => application_name,
      }

      @logger ||= self.class.logger.tag(tags)
    end

    def log(level, message, data = {})
      logger.send(level, message, base_log_data.merge(data))
    end

    def base_log_data
      { :attributes => @attributes }
    end
  end
end
