# coding: UTF-8

require "membrane"

require "dea/runtime"

module Dea
  class Config
    EMPTY_CONFIG = {
      "intervals" => {},
      "status"    => {},
      "resources" => {},
      "crash_lifetime_secs" => 60 * 60,
      "evacuation_delay_secs" => 30,
      "bind_mounts" => [],
      "only_production_apps" => false,
    }

    def self.schema
      ::Membrane::SchemaParser.parse do
        {
          "base_dir" => String,
          optional("local_route") => String,
          "logging" => {
            "level"            => String,
            optional("file")   => String,
            optional("syslog") => String,
          },
          "only_production_apps" => bool,
          "nats_uri" => String,
          "pid_filename" => String,
          "runtimes" => [String],
          "warden_socket" => String,
          "index" => Integer,

          "directory_server_port" => Integer,
          "directory_server_v2_port" => Integer,
          "file_api_port" => Integer,

          optional("crash_lifetime_secs") => Integer,

          optional("evacuation_delay_secs") => Integer,

          optional("status") => {
            optional("user")     => String,
            optional("port")     => Integer,
            optional("password") => String,
          },

          optional("intervals") => {
            optional("heartbeat") => Integer,
            optional("advertise") => Integer,
          },

          optional("resources") => {
            optional("memory_mb") => Integer,
            optional("memory_overcommit_factor") => enum(Float, Integer),

            optional("disk_mb") => Integer,
            optional("disk_overcommit_factor") => enum(Float, Integer),

            optional("num_instances") => Integer,
          },

          optional("bind_mounts") => [{
            "src_path" => String,
            optional("dst_path") => String,
            optional("mode")     => enum("ro", "rw"),
          }],
        }
      end
    end

    include Enumerable

    def initialize(config)
      @config = EMPTY_CONFIG.merge(config)
    end

    def [](k)
      @config[k]
    end

    def []=(k, v)
      @config[k] = v
    end

    def each(&blk)
      @config.each(&blk)
    end

    def validate
      self.class.schema.validate(@config)
    end

    def only_production_apps?
      self["only_production_apps"]
    end
  end
end
