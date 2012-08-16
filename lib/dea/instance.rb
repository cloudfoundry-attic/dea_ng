# coding: UTF-8

require "em/warden/client/connection"
require "membrane"
require "steno"
require "steno/core_ext"
require "vcap/common"

require "dea/env"
require "dea/event_emitter"
require "dea/promise"

module Dea
  class Instance
    include EventEmitter

    STAT_COLLECTION_INTERVAL_SECS = 1

    BIND_MOUNT_MODE_MAP = {
      "ro" =>  ::Warden::Protocol::CreateRequest::BindMount::Mode::RO,
      "rw" =>  ::Warden::Protocol::CreateRequest::BindMount::Mode::RW,
    }

    class State
      BORN     = "BORN"

      # Lifted from the old dea. These are emitted in heartbeat messages and
      # are used by the hm, consequently it must be updated if these are
      # changed.
      STARTING = "STARTING"
      RUNNING  = "RUNNING"
      STOPPED  = "STOPPED"
      CRASHED  = "CRASHED"
      DELETED  = "DELETED"
    end

    class Transition < Struct.new(:from, :to)
      def initialize(*args)
        super(*args.map(&:to_s).map(&:downcase))
      end
    end

    class BaseError < StandardError
    end

    class RuntimeNotFoundError < BaseError
      attr_reader :data

      def initialize(runtime)
        @data = { :runtime_name => runtime }
      end

      def message
        "Runtime not found: #{data[:runtime_name].inspect}"
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

    class WardenError < BaseError
    end

    def self.translate_attributes(attributes)
      attributes = attributes.dup

      attributes["instance_index"]      = attributes.delete("index")

      attributes["application_id"]      = attributes.delete("droplet")
      attributes["application_version"] = attributes.delete("version")
      attributes["application_name"]    = attributes.delete("name")
      attributes["application_uris"]    = attributes.delete("uris")
      attributes["application_users"]   = attributes.delete("users")

      attributes["droplet_sha1"]        = attributes.delete("sha1")
      attributes["droplet_uri"]         = attributes.delete("executableUri")

      attributes["runtime_name"]        = attributes.delete("runtime")
      attributes["framework_name"]      = attributes.delete("framework")

      # Translate environment to dictionary (it is passed as Array with VAR=VAL)
      env = attributes.delete("env") || {}
      attributes["environment"] = Hash[env.map do |e|
        e.split("=", 2)
      end]

      attributes
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
          "name"         => String,
          "type"         => String,
          "label"        => String,
          "vendor"       => String,
          "version"      => String,
          "tags"         => any,
          "plan"         => String,
          "plan_option" => String,
          "credentials"  => dict(String, String),
        }
      end
    end

    def self.schema
      limits_schema = self.limits_schema
      service_schema = self.service_schema

      Membrane::SchemaParser.parse do
        {
          # Static attributes (coming from cloud controller):
          "instance_id"         => String,
          "instance_index"      => Integer,

          "application_id"      => Integer,
          "application_version" => String,
          "application_name"    => String,
          "application_uris"    => [String],
          "application_users"   => [String],

          "droplet_sha1"        => String,
          "droplet_uri"         => String,

          "runtime_name"        => String,
          "framework_name"      => String,

          # TODO: use proper schema
          "limits"              => limits_schema,
          "environment"         => dict(String, String),
          "services"            => [service_schema],
          optional("flapping")  => bool,

          optional("debug")     => enum(nil, String),
          optional("console")   => enum(nil, bool),
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
    attr_reader :start_timestamp
    attr_reader :used_memory_in_bytes
    attr_reader :used_disk_in_bytes
    attr_reader :computed_pcpu    # See `man ps`

    def initialize(bootstrap, attributes)
      @bootstrap  = bootstrap
      @attributes = attributes.dup
      @attributes["application_uris"] ||= []

      # Generate unique ID
      @attributes["instance_id"] = VCAP.secure_uuid
      self.state = State::BORN

      # Cache for warden connections for this instance
      @warden_connections = {}

      @used_memory_in_bytes  = 0
      @used_disk_in_bytes    = 0
      @computed_pcpu         = 0
      @cpu_samples           = []
      @stat_collection_timer = nil
    end

    # TODO: Fill in once start is hooked up
    def flapping?
      false
    end

    def runtime
      bootstrap.runtimes[self.runtime_name]
    end

    def memory_limit_in_bytes
      # Adds a little bit of headroom (inherited from DEA v1)
      ((limits["mem"].to_i * 1024 * 9) / 8) * 1024
    end

    def disk_limit_in_bytes
      limits["disk"].to_i * 1024 * 1024
    end

    def file_descriptor_limit
      limits["fds"].to_i
    end

    def validate
      self.class.schema.validate(@attributes)

      # Check if the runtime is available
      if runtime.nil?
        error = RuntimeNotFoundError.new(self.runtime_name)
        logger.warn(error.message, error.data)
        raise error
      end
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
      promise_state = Promise.new do
        if !Array(from).include?(state)
          promise_state.fail(TransitionError.new(state, to))
        else
          if to
            self.state = to
          end

          promise_state.deliver
        end
      end
    end

    def promise_droplet_download
      promise_droplet_download = Promise.new do
        droplet.download(droplet_uri) do |error|
          if error
            promise_droplet_download.fail(error)
          else
            promise_droplet_download.deliver
          end
        end
      end
    end

    def promise_warden_connection(name)
      Promise.new do |p|
        connection = @warden_connections[name]

        # Deliver cached connection if possible
        if connection && connection.connected?
          p.deliver(connection)
        else
          socket = bootstrap.config["warden_socket"]
          klass  = ::EM::Warden::Client::Connection

          begin
            connection = ::EM.connect_unix_domain(socket, klass)
          rescue => error
            p.fail(WardenError.new("Cannot connect to warden on #{socket}: #{error.message}"))
          end

          if connection
            connection.on(:connected) do
              # Cache connection
              @warden_connections[name] = connection

              p.deliver(connection)
            end

            connection.on(:disconnected) do
              p.fail(WardenError.new("Cannot connect to warden on #{socket}"))
            end
          end
        end
      end
    end

    def promise_warden_call(connection, request)
      Promise.new do |p|
        logger.debug2(request.inspect)
        connection.call(request) do |result|
          logger.debug2(result.inspect)

          error = nil

          begin
            response = result.get
          rescue => error
          end

          if error
            logger.warn "Request failed: #{request.inspect}"
            logger.log_exception(error)

            p.fail(error)
          else
            p.deliver(response)
          end
        end
      end
    end

    def promise_create_container
      Promise.new do |p|
        connection = promise_warden_connection(:app).resolve

        # Droplet and runtime
        bind_mounts = [droplet.droplet_dirname, runtime.dirname].map do |path|
          bind_mount = ::Warden::Protocol::CreateRequest::BindMount.new
          bind_mount.src_path = path
          bind_mount.dst_path = path
          bind_mount.mode = ::Warden::Protocol::CreateRequest::BindMount::Mode::RO
          bind_mount
        end

        # Extra mounts (these typically include libs like pq, mysql, etc)
        bootstrap.config["bind_mounts"].each do |bm|
          bind_mount = ::Warden::Protocol::CreateRequest::BindMount.new

          bind_mount.src_path = bm["src_path"]
          bind_mount.dst_path = bm["dst_path"] || bm["src_path"]

          mode = bm["mode"] || "ro"
          bind_mount.mode = BIND_MOUNT_MODE_MAP[mode]

          bind_mounts << bind_mount
        end

        create_request = ::Warden::Protocol::CreateRequest.new
        create_request.bind_mounts = bind_mounts

        response = promise_warden_call(connection, create_request).resolve

        @attributes["warden_handle"] = response.handle

        @logger = logger.tag("warden_handle" => response.handle)

        p.deliver
      end
    end

    def promise_setup_network
      Promise.new do |p|
        connection = promise_warden_connection(:app).resolve

        net_in = lambda do
          request = ::Warden::Protocol::NetInRequest.new
          request.handle = @attributes["warden_handle"]
          promise_warden_call(connection, request).resolve
        end

        if !attributes["application_uris"].empty?
          response = net_in.call
          attributes["instance_host_port"]      = response.host_port
          attributes["instance_container_port"] = response.container_port
        end

        if attributes["debug"]
          response = net_in.call
          attributes["instance_debug_host_port"]      = response.host_port
          attributes["instance_debug_container_port"] = response.container_port
        end

        if attributes["console"]
          response = net_in.call
          attributes["instance_console_host_port"]      = response.host_port
          attributes["instance_console_container_port"] = response.container_port
        end

        p.deliver
      end
    end

    def promise_limit_disk
      Promise.new do |p|
        connection = promise_warden_connection(:app).resolve

        request = ::Warden::Protocol::LimitDiskRequest.new
        request.handle = @attributes["warden_handle"]
        request.byte = disk_limit_in_bytes
        promise_warden_call(connection, request).resolve

        p.deliver
      end
    end

    def promise_limit_memory
      Promise.new do |p|
        connection = promise_warden_connection(:app).resolve

        request = ::Warden::Protocol::LimitMemoryRequest.new
        request.handle = @attributes["warden_handle"]
        request.limit_in_bytes = memory_limit_in_bytes
        promise_warden_call(connection, request).resolve

        p.deliver
      end
    end

    def promise_warden_run(connection, script)
      Promise.new do |p|
        request = ::Warden::Protocol::RunRequest.new
        request.handle = attributes["warden_handle"]
        request.script = script
        response = promise_warden_call(connection, request).resolve

        if response.exit_status > 0
          data = {
            :script      => script,
            :exit_status => response.exit_status,
            :stdout      => response.stdout,
            :stderr      => response.stderr,
          }

          logger.warn("%s exited with status %d" % [script.inspect, response.exit_status], data)
          p.fail(WardenError.new("Script exited with status %d" % response.exit_status))
        else
          p.deliver(response)
        end
      end
    end

    def promise_extract_droplet
      Promise.new do |p|
        connection = promise_warden_connection(:app).resolve
        script = "tar zxf #{droplet.droplet_path}"

        promise_warden_run(connection, script).resolve

        p.deliver
      end
    end

    def promise_prepare_start_script
      Promise.new do |p|
        connection = promise_warden_connection(:app).resolve
        script = "sed -i 's@%VCAP_LOCAL_RUNTIME%@#{runtime.executable}@g' startup"

        promise_warden_run(connection, script).resolve

        p.deliver
      end
    end

    def promise_start
      Promise.new do |p|
        script = []
        script << "renice 0 $$"
        script << "ulimit -n %d" % self.file_descriptor_limit
        script << "ulimit -u %d" % 512
        script << "umask 077"

        env = Env.new(self)
        env.env.each do |(key, value)|
          script << "export %s=%s" % [key, value]
        end

        startup = "./startup"

        # Pass port to `startup` if we have one
        if self.instance_host_port
          startup << " -p %d" % self.instance_host_port
        end

        script << startup
        script << "exit"

        connection = promise_warden_connection(:app).resolve

        request = ::Warden::Protocol::SpawnRequest.new
        request.handle = attributes["warden_handle"]
        request.script = script.join("\n")
        response = promise_warden_call(connection, request).resolve

        attributes["warden_job_id"] = response.job_id

        p.deliver
      end
    end

    def promise_container_info
      Promise.new do |p|
        conn = promise_warden_connection(:info).resolve

        handle = @attributes["warden_handle"]
        request = ::Warden::Protocol::InfoRequest.new(:handle => handle)

        response = promise_warden_call(conn, request).resolve
        @attributes["warden_container_path"] = response.container_path

        p.deliver(response)
      end
    end

    def start(&callback)
      p = Promise.new do
        logger.info("Starting instance")

        promise_state(State::BORN, State::STARTING).resolve

        promise_droplet = Promise.new do |p|
          if !droplet.droplet_exist?
            logger.info("Starting droplet download")
            promise_droplet_download.resolve
          else
            logger.info("Skipping droplet download")
          end

          p.deliver
        end

        promise_container = Promise.new do |p|
          promise_create_container.resolve
          promise_setup_network.resolve
          promise_limit_disk.resolve
          promise_limit_memory.resolve

          p.deliver
        end

        # Concurrently download droplet and setup container
        [promise_droplet, promise_container].each(&:run).each(&:resolve)

        start_stat_collector

        promise_setup_network.resolve

        promise_extract_droplet.resolve

        promise_prepare_start_script.resolve

        promise_start.resolve

        promise_state(State::STARTING, State::RUNNING).resolve

        p.deliver
      end

      resolve(p, "start instance") do |error, _|
        if error
          # An error occured while starting, mark as crashed
          self.state = State::CRASHED
        else
          # Instance is started, start waiting for it to exit
          EM.next_tick { link }
        end

        callback.call(error) unless callback.nil?
      end
    end

    def promise_stop
      Promise.new do |p|
        connection = promise_warden_connection(:app).resolve

        request = ::Warden::Protocol::StopRequest.new
        request.handle = attributes["warden_handle"]
        response = promise_warden_call(connection, request).resolve

        p.deliver
      end
    end

    def stop(&callback)
      p = Promise.new do
        logger.info("Stopping instance")

        promise_state(State::RUNNING, State::STOPPED).resolve

        promise_stop.resolve

        p.deliver
      end

      resolve(p, "stop instance") do |error, _|
        callback.call(error) unless callback.nil?
      end
    end

    def start_stat_collector
      Promise.resolve(promise_collect_stats) do
        @stat_collection_timer =
          EM.add_timer(STAT_COLLECTION_INTERVAL_SECS) { start_stat_collector }
      end
    end

    def promise_collect_stats
      Promise.new do |p|
        begin
          info_resp = promise_container_info.resolve
        rescue => error
          logger.error("Failed getting container info: #{error}")
          raise
        end

        @used_memory_in_bytes = info_resp.memory_stat.rss * 1024

        @used_disk_in_bytes = info_resp.disk_stat.bytes_used

        now = Time.now

        @cpu_samples << {
          :timestamp_ns => now.to_i * 1_000_000_000 + now.nsec,
          :ns_used      => info_resp.cpu_stat.usage,
        }

        @cpu_samples.unshift if @cpu_samples.size > 2

        if @cpu_samples.size == 2
          used = @cpu_samples[1][:ns_used] - @cpu_samples[0][:ns_used]
          elapsed = @cpu_samples[1][:timestamp_ns] - @cpu_samples[0][:timestamp_ns]

          if elapsed > 0
            @computed_pcpu = used.to_f / elapsed
          end
        end

        p.deliver
      end
    end

    def destroy_crash_artifacts
      # TODO: Fill in
    end

    def promise_link
      Promise.new do |p|
        response = nil

        begin
          logger.info("Linking")

          connection = promise_warden_connection(:link).resolve

          request = ::Warden::Protocol::LinkRequest.new
          request.handle = attributes["warden_handle"]
          request.job_id = attributes["warden_job_id"]
          response = promise_warden_call(connection, request).resolve

        rescue ::EM::Warden::Client::ConnectionError => error
          logger.warn("Linking failed, retrying")
          logger.log_exception(error)
          retry
        end

        logger.info("Linking completed with exit status: %d" % response.exit_status)

        p.deliver(response)
      end
    end

    def link(&callback)
      Promise.resolve(promise_link) do |error, _|
        uptime = Time.now - attributes["state_running_timestamp"]
        logger.info("Instance uptime: %.3fs" % uptime)

        # Move to "crashed" state if it was "running"
        if self.state == State::RUNNING
          self.state = State::CRASHED
        else
          # Linking likely completed because of stop
        end

        callback.call(error) unless callback.nil?
      end
    end

    private

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

    # Resolve a promise making sure that only one runs at a time.
    def resolve(p, name)
      if @busy
        logger.warn("Ignored: #{name}")
        return
      else
        @busy = true

        Promise.resolve(p) do |error, result|
          begin
            took = "took %.3f" % p.elapsed_time

            if error
              logger.warn("Failed: #{name} (#{took})")
              logger.log_exception(error)
            else
              logger.info("Delivered: #{name} (#{took})")
            end

            yield(error, result)
          ensure
            @busy = false
          end
        end
      end
    end
  end
end
