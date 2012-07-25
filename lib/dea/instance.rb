# coding: UTF-8

require "em/warden/client/connection"
require "membrane"
require "steno"
require "steno/core_ext"
require "vcap/common"

require "dea/promise"

module Dea
  class Instance
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
          "debug"               => any,
          "console"             => any,
        }
      end
    end

    # Define an accessor for every attribute with a schema
    self.schema.schemas.each do |key, _|
      define_method(key) do
        attributes[key]
      end
    end

    attr_reader :bootstrap
    attr_reader :attributes

    def initialize(bootstrap, attributes)
      @bootstrap  = bootstrap
      @attributes = attributes.dup

      # Generate unique ID
      @attributes["instance_id"] = VCAP.secure_uuid
      @attributes["state"] = "born"
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

    def promise_droplet_available
      promise_droplet_available = Promise.new do
        unless droplet.droplet_exist?
          promise_droplet_download.resolve
        end

        promise_droplet_available.deliver
      end
    end

    def promise_create_warden_connection
      Promise.new do |p|
        socket     = bootstrap.config["warden_socket"]
        klass      = ::EM::Warden::Client::Connection

        begin
          connection = ::EM.connect_unix_domain(socket, klass)
        rescue => error
          p.fail(WardenError.new("Cannot connect to warden on #{socket}: #{error.message}"))
        end

        if connection
          connection.on(:connected) do
            p.deliver(connection)
          end

          connection.on(:disconnected) do
            p.fail(WardenError.new("Cannot connect to warden on #{socket}"))
          end
        end
      end
    end

    def start(&callback)
      p = Promise.new do
        promise_state(:from => "born", :to => "start").resolve
        promise_droplet_available.resolve
        promise_create_warden_connection.resolve

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
