# coding: UTF-8

require "vcap/common"
require "membrane"
require "steno"
require "steno/core_ext"

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
      self.state = State::BORN
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

    def start(&callback)
      promise_state = Promise.new do |p|
        if state != State::BORN
          p.fail(TransitionError.new(State::BORN, State::STARTING))
        else
          p.deliver
        end
      end

      promise_droplet_download = Promise.new do |p|
        droplet.download(droplet_uri) do |error|
          if error
            p.fail(error)
          else
            p.deliver
          end
        end
      end

      promise_droplet_available = Promise.new do |p|
        unless droplet.droplet_exist?
          promise_droplet_download.resolve
        end

        p.deliver
      end

      promise_start = Promise.new do |p|
        promise_state.resolve
        promise_droplet_available.resolve
      end

      Promise.resolve(promise_start) do |error, result|
        callback.call(error)
      end
    end

    # Corresponds to the per-instance heartbeat generated by the old dea.
    def generate_heartbeat
      { "droplet"         => application_id,
        "version"         => application_version,
        "instance"        => instance_id,
        "index"           => instance_index,
        "state"           => state,
        "state_timestamp" => state_timestamp,
      }
    end

    def generate_find_droplet_response(include_stats)
      response = {
        "dea"             => bootstrap.uuid,
        "droplet"         => application_id,
        "version"         => application_version,
        "instance"        => instance_id,
        "index"           => instance_index,
        "state"           => state,
        "state_timestamp" => state_timestamp,

        # TODO: Include once file viewer is live
        # file_uri
        # credentials
        # staged

        # TODO: Include once debug/console is filled out
        # debug_ip
        # debug_port
        # console_ip
        # console_port
      }

      if include_stats
        response["stats"] = {
          "name" => application_name,
          "uris" => application_uris,

          # TODO: Include once start command is hooked up
          # host
          # port
          # uptime
          # mem_quota
          # disk_quota
          # cores
        }
      end

      response
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
