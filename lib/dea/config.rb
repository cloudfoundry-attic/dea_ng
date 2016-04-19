# coding: UTF-8

require "membrane"

module Dea
  class Config
    DEFAULT_STAGING_DISK_INODE_LIMIT = 200_000
    DEFAULT_INSTANCE_DISK_INODE_LIMIT = 200_000
    DEFAULT_INSTANCE_NPROC_LIMIT = 512
    DEFAULT_ROUTER_REGISTER_INTERVAL_IN_SECONDS = 20
    DEFAULT_CA_CERT_FILE = '/etc/ssl/certs/ca-certificates.crt'

    EMPTY_CONFIG = {
      "intervals" => {
        "router_register_in_seconds" => DEFAULT_ROUTER_REGISTER_INTERVAL_IN_SECONDS,
      },
      "status" => {},
      "resources" => {},
      "crash_lifetime_secs" => 60 * 60,
      "evacuation_bail_out_time_in_seconds" => 10 * 60,
      "bind_mounts" => [],
      "crash_block_usage_ratio_threshold" => 0.8,
      "crash_inode_usage_ratio_threshold" => 0.8,
      "placement_properties" => { "zone" => "default" },
      "instance" => {
        "memory_to_cpu_share_ratio" => 8,
        "max_cpu_share_limit" => 256,
        "min_cpu_share_limit" => 1,
        "disk_inode_limit" => DEFAULT_INSTANCE_DISK_INODE_LIMIT,
        "nproc_limit" => DEFAULT_INSTANCE_NPROC_LIMIT,
      },
      "stacks" => [],
      "staging" => {
        "cpu_limit_shares" => 512,
        "disk_inode_limit" => DEFAULT_STAGING_DISK_INODE_LIMIT,
      },
      "default_health_check_timeout" => 60,
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

          "stacks" => [
            {
              "name" => String,
              "package_path" => String,
            }
          ],

          "placement_properties" => {
            "zone" => String
          },

          "cc_url" => String,

          "hm9000" => {
            "listener_uri" => String,
            "key_file" => String,
            "cert_file" => String,
            "ca_file" => String,
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
            optional("router_register_in_seconds") => enum(Float, Integer),
            optional("heartbeat") => Integer,
            optional("advertise") => Integer,
          },

          optional("resources") => {
            optional("memory_mb") => Integer,
            optional("memory_overcommit_factor") => enum(Float, Integer),

            optional("disk_mb") => Integer,
            optional("disk_overcommit_factor") => enum(Float, Integer),
          },

          optional("bind_mounts") => [
            {
              "src_path" => String,
              optional("dst_path") => String,
              optional("mode") => enum("ro", "rw"),
            }
          ],

          optional("hooks") => {
            optional("before_start") => String,
            optional("after_start") => String,
            optional("before_stop") => String,
            optional("after_stop") => String
          },

          optional("instance") => {
            "memory_to_cpu_share_ratio" => Integer,
            "max_cpu_share_limit" => Integer,
            "min_cpu_share_limit" => Integer,
            "disk_inode_limit" => Integer,
            optional("nproc_limit") => Integer,
            optional("bandwidth_limit") => {
              "rate" => Integer,
              "burst" => Integer,
            },
          },

          optional("staging") => {
            optional("enabled") => bool,
            optional("max_staging_duration") => Integer,
            optional("environment") => Hash,
            optional("memory_limit_mb") => Integer,
            optional("disk_limit_mb") => Integer,
            optional("cpu_limit_shares") => Integer,
            optional("bandwidth_limit") => {
              "rate" => Integer,
              "burst" => Integer,
            },
          },

          optional("post_setup_hook") => String,

          optional("ssl") => {
            "port" => Integer,
            "key_file" => String,
            "cert_file" => String,
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
      validate_router_register_interval!
      verify_hm9000_certs
      verify_ssl_certs
    end

    def validate_router_register_interval!
      @config["intervals"]["router_register_in_seconds"] ||= DEFAULT_ROUTER_REGISTER_INTERVAL_IN_SECONDS
      raise "Invalid router register interval" if @config["intervals"]["router_register_in_seconds"] <= 0
    end

    def verify_hm9000_certs
      hm9000 = @config['hm9000']

      missing_files = []
      ['key_file', 'cert_file', 'ca_file'].each do |file|
        missing_files << hm9000[file] if !File.exists?(hm9000[file])
      end

      return if missing_files.length == 0

      raise "Invalid HM9000 Certs: One or more files not found: #{missing_files.join(', ')}"
    end

    def verify_ssl_certs
      ssl = @config['ssl']

      if ssl
        missing_files = []
        ['key_file', 'cert_file'].each do |file|
          missing_files << ssl[file] if !File.exists?(ssl[file])
        end

        return if missing_files.length == 0

        raise "Invalid SSL Certs: One or more files not found: #{missing_files.join(', ')}"
      end
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

    def instance_nproc_limit
      @config.fetch("instance", {}).fetch("nproc_limit", DEFAULT_INSTANCE_NPROC_LIMIT)
    end

    def staging_bandwidth_limit
      @config.fetch("staging", {})["bandwidth_limit"]
    end

    def instance_bandwidth_limit
      @config.fetch("instance", {})["bandwidth_limit"]
    end

    def rootfs_path(stack_name)
      stack = @config['stacks'].find { |stack_hash| stack_hash['name'] == stack_name }
      stack['package_path'] unless stack.nil?
    end

    def post_setup_hook
      @config['post_setup_hook']
    end
  end
end
