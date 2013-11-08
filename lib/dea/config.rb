# coding: UTF-8

require "membrane"

module Dea
  class Config
    DEFAULT_STAGING_DISK_INODE_LIMIT = 200_000
    DEFAULT_INSTANCE_DISK_INODE_LIMIT = 200_000

    EMPTY_CONFIG = {
      "intervals" => {},
      "status" => {},
      "resources" => {},
      "crash_lifetime_secs" => 60 * 60,
      "evacuation_bail_out_time_in_seconds" => 10 * 60,
      "bind_mounts" => [],
      "crash_block_usage_ratio_threshold" => 0.8,
      "crash_inode_usage_ratio_threshold" => 0.8,
      "placement_properties" => { "zone" => "default" },
      "instance" => {
        "cpu_limit_shares" => 256,
        "disk_inode_limit" => DEFAULT_INSTANCE_DISK_INODE_LIMIT,
      },
      "staging" => {
        "cpu_limit_shares" => 512,
        "disk_inode_limit" => DEFAULT_STAGING_DISK_INODE_LIMIT,
      },
      "default_health_check_timeout" => 60
    }

    def self.schema
      ::Membrane::SchemaParser.parse do
        {
          "base_dir" => String,

          "logging" => {
            "level" => String,
            optional("file") => String,
            optional("syslog") => String,
          },

          "nats_servers" => [String],
          "pid_filename" => String,
          "warden_socket" => String,
          "index" => Integer,

          "directory_server" => {
            "protocol" => String,
            "v2_port" => Integer,
            "file_api_port" => Integer,
          },

          "stacks" => [String],
          "placement_properties" => {
            "zone" => String
          },

          optional("crash_lifetime_secs") => Integer,
          optional("crash_block_usage_ratio_threshold") => Float,
          optional("crash_inode_usage_ratio_threshold") => Float,

          optional("evacuation_bail_out_time_in_seconds") => Integer,

          optional("default_health_check_timeout") => Integer,

          optional("status") => {
            optional("user") => String,
            optional("port") => Integer,
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

            optional("max_instances") => Integer,
          },

          optional("bind_mounts") => [{
                                        "src_path" => String,
                                        optional("dst_path") => String,
                                        optional("mode") => enum("ro", "rw"),
                                      }],

          optional("hooks") => {
            optional("before_start") => String,
            optional("after_start") => String,
            optional("before_stop") => String,
            optional("after_stop") => String
          },

          optional("instance") => {
            optional("cpu_limit_shares") => Integer,
            optional("disk_inode_limit") => Integer
          },

          optional("staging") => {
            optional("enabled") => bool,
            optional("max_staging_duration") => Integer,
            optional("environment") => Hash,
            optional("memory_limit_mb") => Integer,
            optional("disk_limit_mb") => Integer,
            optional("cpu_limit_shares") => Integer
          }
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

    def staging_disk_inode_limit
      @config.fetch("staging", {}).fetch("disk_inode_limit", DEFAULT_STAGING_DISK_INODE_LIMIT)
    end

    def instance_disk_inode_limit
      @config.fetch("instance", {}).fetch("disk_inode_limit", DEFAULT_INSTANCE_DISK_INODE_LIMIT)
    end
  end
end
