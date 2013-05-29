# coding: UTF-8

require "membrane"

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
      "crash_block_usage_ratio_threshold" => 0.8,
      "crash_inode_usage_ratio_threshold" => 0.8,
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
          "warden_socket" => String,
          "index" => Integer,

          "directory_server" => {
            "v1_port" => Integer,
            "v2_port" => Integer,
            "file_api_port" => Integer,
          },

          "stacks" => [String],

          optional("crash_lifetime_secs") => Integer,
          optional("crash_block_usage_ratio_threshold") => Float,
          optional("crash_inode_usage_ratio_threshold") => Float,

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

          optional('hooks') => {
            optional('before_start') => String,
            optional('after_start')  => String,
            optional('before_stop')  => String,
            optional('after_stop')   => String
          },
        }
      end
    end

    include Enumerable

    def self.from_file(file_path)
      new(YAML.load_file(file_path)).tap(&:validate)
    end

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

    def crashes_path
      @crashes_path ||= File.join(self["base_dir"], "crashes")
    end

    def crash_block_usage_ratio_threshold
      self["crash_block_usage_ratio_threshold"]
    end

    def crash_inode_usage_ratio_threshold
      self["crash_inode_usage_ratio_threshold"]
    end

    def minimum_staging_memory_mb
      @config.fetch("staging", {}).fetch("memory_limit_mb", 1024)
    end

    def minimum_staging_disk_mb
      @config.fetch("staging", {}).fetch("disk_limit_mb", 2*1024)
    end
  end
end
