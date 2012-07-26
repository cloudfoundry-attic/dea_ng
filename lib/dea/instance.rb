# coding: UTF-8

require "em/warden/client/connection"
require "membrane"
require "steno"
require "steno/core_ext"
require "vcap/common"

require "dea/promise"

module Dea
  class Instance
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

      def initialize(from, to)
        @from = from
        @to = to
      end

      def message
        "Cannot transition from #{from.inspect} to #{to.inspect}"
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
      attributes["droplet_file"]        = attributes.delete("executableFile")
      attributes["droplet_uri"]         = attributes.delete("executableUri")

      attributes["runtime_name"]        = attributes.delete("runtime")
      attributes["framework_name"]      = attributes.delete("framework")

      attributes["environment"]         = attributes.delete("env")

      attributes
    end

    def self.schema
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
          "droplet_file"        => String,
          "droplet_uri"         => String,

          "runtime_name"        => String,
          "framework_name"      => String,

          # TODO: use proper schema
          "limits"              => any,
          "environment"         => any,
          "services"            => any,
          "flapping"            => any,

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

    # Accessors for debug/console ports
    %W[instance_debug_host_port instance_console_host_port].each do |key|
      define_method(key) { attributes[key] }
    end

    # Helper method needed for creating a new scope
    def self.define_state_predicate(state)
      define_method("#{state.to_s.downcase}?") do
        self.state == state
      end
    end

    # Define predicate methods for querying state
    State.constants.each { |state| define_state_predicate(State.const_get(state)) }

    attr_reader :bootstrap
    attr_reader :attributes

    def initialize(bootstrap, attributes)
      @bootstrap  = bootstrap
      @attributes = attributes.dup
      @attributes["application_uris"] ||= []

      # Generate unique ID
      @attributes["instance_id"] = VCAP.secure_uuid
      self.state = State::BORN

      # Cache for warden connections for this instance
      @warden_connections = {}
    end

    def validate
      self.class.schema.validate(@attributes)

      # Check if the runtime is available
      if bootstrap.runtimes[self.runtime_name].nil?
        error = RuntimeNotFoundError.new(self.runtime_name)
        logger.warn(error.message, error.data)
        raise error
      end
    end

    def state
      attributes["state"]
    end

    def state=(state)
      attributes["state"] = state
      # This diverges from the old implementation (used to_i) but is more
      # correct.
      attributes["state_timestamp"] = Time.now.to_f
    end

    def state_timestamp
      attributes["state_timestamp"]
    end

    def droplet
      bootstrap.droplet_registry[droplet_sha1]
    end

    def promise_state(options)
      promise_state = Promise.new do
        if !Array(options[:from]).include?(state)
          promise_state.fail(TransitionError.new(state, options[:to] || "<unknown>"))
        else
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
        connection.call(request) do |result|
          error = nil

          begin
            response = result.get
          rescue => error
          end

          if error
            p.fail(error)
          else
            p.deliver(response)
          end
        end
      end
    end

    def promise_create_container(connection)
      Promise.new do |p|
        droplet_directory_bind_mount = ::Warden::Protocol::CreateRequest::BindMount.new
        droplet_directory_bind_mount.src_path = droplet.droplet_directory
        droplet_directory_bind_mount.dst_path = droplet.droplet_directory
        droplet_directory_bind_mount.mode = ::Warden::Protocol::CreateRequest::BindMount::Mode::RO

        create_request = ::Warden::Protocol::CreateRequest.new
        create_request.bind_mounts = [droplet_directory_bind_mount]

        response = promise_warden_call(connection, create_request).resolve

        @attributes["warden_handle"] = response.handle

        p.deliver
      end
    end

    def promise_setup_network(connection)
      Promise.new do |p|
        net_in = lambda do
          request = ::Warden::Protocol::NetInRequest.new
          request.handle = @attributes["warden_handle"]
          promise_warden_call(connection, request).resolve
        end

        response = net_in.call
        attributes["instance_host_port"]      = response.host_port
        attributes["instance_container_port"] = response.container_port

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

    def start(&callback)
      p = Promise.new do
        promise_state(:from => State::BORN, :to => State::STARTING).resolve

        promise_droplet = Promise.new do |p|
          unless droplet.droplet_exist?
            promise_droplet_download.resolve
          end

          p.deliver
        end

        promise_container = Promise.new do |p|
          connection = promise_warden_connection(:app).resolve
          promise_create_container(connection).resolve

          p.deliver
        end

        # Concurrently download droplet and create container
        [promise_droplet, promise_container].each(&:run).each(&:resolve)

        promise_network = Promise.new do |p|
          connection = promise_warden_connection(:app).resolve
          promise_setup_network(connection).resolve

          p.deliver
        end

        promise_network.resolve

        p.deliver
      end

      Promise.resolve(p) do |error, result|
        callback.call(error)
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
  end
end
