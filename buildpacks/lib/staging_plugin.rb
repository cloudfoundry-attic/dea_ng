require 'yaml'
require 'erb'
require 'tmpdir'

module Buildpacks
  class StagingPlugin
    attr_accessor :source_directory, :destination_directory, :staging_info_path, :environment_json

    def self.platform_config
      YAML.load_file(ENV['PLATFORM_CONFIG'])
    end

    def self.validate_arguments!(*args)
      source, dest, env = args
      argfail!(args) unless source && dest && env
      argfail!(args) unless File.directory?(File.expand_path(source))
      argfail!(args) unless File.directory?(File.expand_path(dest))
    end

    def self.argfail!(args)
      puts "Invalid arguments for staging: #{args.inspect}"
      exit 1
    end

    def self.from_file(file_path)
      config = YAML.load_file(file_path)
      validate_arguments!(config["source_dir"], config["dest_dir"], config["environment"])
      new(config)
    end

    def initialize(config = {})
      @source_directory = File.expand_path(config["source_dir"])
      @destination_directory = File.expand_path(config["dest_dir"])
      @environment = config["environment"]
      @staging_info_path = config["staging_info_path"]
      @cache_dir = config["cache_dir"]
    end

    def app_dir
      File.join(destination_directory, "app")
    end

    def log_dir
      File.join(destination_directory, "logs")
    end

    def tmp_dir
      File.join(destination_directory, "tmp")
    end

    def cache_dir
      @cache_dir || "/tmp/cache"
    end

    def script_dir
      destination_directory
    end

    def stage_application
      raise NotImplementedError, "subclasses must implement a 'stage_application' method"
    end

    def environment
      @environment
    end

    def start_command
      raise NotImplementedError, "subclasses must implement a 'start_command' method that returns a string"
    end

    def application_memory
      if environment["resources"] && environment["resources"]["memory"]
        environment["resources"]["memory"]
      else
        512 #MB
      end
    end

    def change_directory_for_start
      "cd app"
    end

    def get_launched_process_pid
      "STARTED=$!"
    end

    def wait_for_launched_process
      "wait $STARTED"
    end

    def pidfile_dir
      "$DROPLET_BASE_DIR"
    end

    def generate_startup_script(env_vars = {})
      after_env_before_script = block_given? ? yield : "\n"
      template = <<-SCRIPT
#!/bin/bash
<%= environment_statements_for(env_vars) %>
<%= after_env_before_script %>
DROPLET_BASE_DIR=$PWD
<%= change_directory_for_start %>
(<%= start_command %>) > $DROPLET_BASE_DIR/logs/stdout.log 2> $DROPLET_BASE_DIR/logs/stderr.log &
<%= get_launched_process_pid %>
echo "$STARTED" >> #{pidfile_dir}/run.pid
<%= wait_for_launched_process %>
      SCRIPT
      # TODO - ERB is pretty irritating when it comes to blank lines, such as when 'after_env_before_script' is nil.
      # There is probably a better way that doesn't involve making the above Heredoc horrible.
      ERB.new(template).result(binding).lines.reject {|l| l =~ /^\s*$/}.join
    end

    # Generates newline-separated exports for the specified environment variables.
    # If the value of one of the keys is false or nil, it will be an 'unset' instead of an 'export'
    def environment_statements_for(vars)
      # Passed vars should overwrite common vars
      common_env_vars = { "TMPDIR" => tmp_dir.gsub(destination_directory,"$PWD") }
      vars = common_env_vars.merge(vars)
      lines = []
      vars.each do |name, value|
        if value
          lines << "export #{name}=\"#{value}\""
        else
          lines << "unset #{name}"
        end
      end
      lines.sort.join("\n")
    end

    def create_app_directories
      FileUtils.mkdir_p(app_dir)
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(tmp_dir)
    end

    def create_startup_script
      path = File.join(script_dir, 'startup')
      File.open(path, 'wb') do |f|
        f.puts startup_script
      end
      FileUtils.chmod(0500, path)
    end

    def bound_services
      environment["services"] || []
    end

    def copy_source_files(dest=nil)
      system "cp -a #{File.join(source_directory, ".")} #{dest || app_dir}"
      FileUtils.chmod_R(0744, app_dir)
    end
  end
end
