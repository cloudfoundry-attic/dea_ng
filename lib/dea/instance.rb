# coding: UTF-8

require "vcap/common"
require "membrane"
require "steno"
require "steno/core_ext"

module Dea
  class Instance
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

    attr_reader :attributes

    def initialize(bootstrap, attributes)
      @bootstrap  = bootstrap
      @attributes = attributes.dup

      # Generate unique ID
      @attributes["instance_id"] = VCAP.secure_uuid

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
