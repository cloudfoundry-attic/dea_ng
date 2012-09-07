require 'vcap/config'
require 'vcap/json_schema'

module VCAP module Dea end end

class VCAP::Dea::Config < VCAP::Config
  DEFAULT_CONFIG_PATH = File.expand_path('../../../../config/dea.yml', __FILE__)

  define_schema do
    {
      :base_dir              => String,     # where all dea stuff lives
      :pid_filename          => String,     # where our pid file lives.
      :reset_at_startup      => VCAP::JsonSchema::BoolSchema.new, #blow away saved state at startup.
      #XXX make this optionally nil, but still in schema:local_route           => String,
      :file_viewer_port      => Integer,
      :domain                => String,
      :resources => {
        :node_limits => {
          :max_memory => Integer,
          :max_disk   => Integer,
          :max_instances => Integer,
        },
        :default_app_quota => {
          :mem_quota => Integer,
          :disk_quota => Integer,
        },
      },
      :nats_uri              => String,     # where nats lives.
      :logging => {
        :level              => String,      # debug, info, etc.
        optional(:file)     => String,      # Log file to use
        optional(:syslog)   => String,      # Name to associate with syslog messages (should start with 'vcap.')
      },

     #XXX add support for mounts: to schema
     :runtimes => VCAP::JsonSchema::HashSchema.new,
     :mount_runtimes => VCAP::JsonSchema::BoolSchema.new, #should we mount the runtime?
    }
  end

  class << self

    def from_file(*args)
      config = super(*args)
      normalize_config(config)
      validate_runtimes(config[:runtimes])
      parse_mounts(config)
      config
    end

    #XXX add support to config parser for checking sequences.
    def parse_mounts(config)
      mounts = config[:mounts] || []
      new_mounts = []
      valid_modes = ['ro','rw'].freeze
      mounts = [] unless mounts
      mounts.each do |line|
        puts "line: #{line}"
        src_path, dst_path, mode = line.split(',').map {|s| s.strip}

        unless Dir.exist?(src_path)
          puts "Directory #{src_path} in mount line #{line} does not exists!."
          exit 1
        end
        unless dst_path
          puts "invalid mount line: #{line}. valid syntax is src_path, dst_path, mode"
          exit 1
        end
        unless valid_modes.include? mode
          puts "invalid mount line: #{line}. mode must be either ro or rw"
          exit 1
        end
        new_mounts.push([src_path, dst_path, mode])
      end
      config[:mounts] = new_mounts
    end

    def validate_runtimes(runtimes)
      if runtimes.nil? || runtimes.empty?
        puts("Can't determine application runtimes, exiting")
        exit 1
      end

      puts("Checking runtimes:")

      runtimes.each do |name, runtime|
        # Only enable when we succeed
        runtime[:enabled] = false
        pname = "#{name}:".ljust(10)

        # Check that we can get a version from the executable
        version_flag = runtime[:version_flag] || '-v'

        expanded_exec = `which #{runtime[:executable]}`
        unless $? == 0
          puts("  #{pname} FAILED, executable '#{runtime[:executable]}' not found")
          next
        end
        expanded_exec.strip!

        # java prints to stderr, so munch them both..
        version_check = `env -i HOME=$HOME #{expanded_exec} #{version_flag} 2>&1`.strip!
        unless $? == 0
          puts("  #{pname} FAILED, executable '#{runtime[:executable]}' not found")
          next
        end
        runtime[:executable] = expanded_exec

        next unless runtime[:version]
        # Check the version for a match
        if /#{runtime[:version]}/ =~ version_check
          # Additional checks should return true
          if runtime[:additional_checks]
            additional_check = `env -i HOME=$HOME #{runtime[:executable]} #{runtime[:additional_checks]} 2>&1`
            unless additional_check =~ /true/i
              puts("  #{pname} FAILED, additional checks failed")
            end
          end
          runtime[:enabled] = true
          puts("  #{pname} OK")
        else
          puts("  #{pname} FAILED, version mismatch (#{version_check})")
        end
      end
      runtimes.delete_if {|name,runtime| runtime[:enabled] == false}
    end

    def normalize_config(config)
      log_level = config[:logging][:level]
      raise "invalid log level #{log_level}." if not %w[debug info warn error debug fatal].include?(log_level)
    end
  end
end
