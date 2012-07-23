# coding: UTF-8

require "vcap/common"
require "steno"
require "steno/core_ext"

module Dea
  class Instance
    module StaticAttributes
      def assign_static_attributes(attributes)
        @attributes["instance_id"]         = VCAP.secure_uuid
        @attributes["instance_index"]      = Integer(attributes["index"])

        @attributes["application_id"]      = Integer(attributes["droplet"])
        @attributes["application_version"] = attributes["version"]
        @attributes["application_name"]    = attributes["name"]
        @attributes["application_uris"]    = attributes["uris"]
        @attributes["application_users"]   = attributes["users"]

        @attributes["droplet_sha1"]        = attributes["sha1"]
        @attributes["droplet_file"]        = attributes["executableFile"]
        @attributes["droplet_uri"]         = attributes["executableUri"]

        @attributes["runtime"]             = attributes["runtime"]
        @attributes["framework"]           = attributes["framework"]

        @attributes["limits"]              = attributes["limits"]
        @attributes["environment"]         = attributes["env"]
        @attributes["services"]            = attributes["services"]
        @attributes["flapping"]            = attributes["flapping"]
        @attributes["debug"]               = attributes["debug"]
        @attributes["console"]             = attributes["console"]
      end

      def instance_id
        @attributes["instance_id"]
      end

      def instance_index
        @attributes["instance_index"]
      end

      def application_id
        @attributes["application_id"]
      end

      def application_version
        @attributes["application_version"]
      end

      def application_name
        @attributes["application_name"]
      end

      def application_uris
        @attributes["application_uris"]
      end

      def application_users
        @attributes["application_users"]
      end

      def droplet_sha1
        @attributes["droplet_sha1"]
      end

      def droplet_file
        @attributes["droplet_file"]
      end

      def droplet_uri
        @attributes["droplet_uri"]
      end

      def runtime
        @attributes["runtime"]
      end

      def framework
        @attributes["framework"]
      end

      def limits
        @attributes["limits"]
      end

      def environment
        @attributes["environment"]
      end

      def services
        @attributes["services"]
      end

      def flapping
        @attributes["flapping"]
      end

      def debug
        @attributes["debug"]
      end

      def console
        @attributes["console"]
      end
    end

    include StaticAttributes

    def self.create_from_message(bootstrap, message)
      new(bootstrap, {}, message.data)
    end

    def initialize(bootstrap, attributes = {}, static_attributes = {})
      @bootstrap  = bootstrap
      @attributes = {}

      unless static_attributes.empty?
        assign_static_attributes(static_attributes)
      end

      # Run-time attributes are either empty, or the full set of
      # attributes as loaded from snapshot
      @attributes = @attributes.merge(attributes)

      logger.debug "initialized instance"
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
