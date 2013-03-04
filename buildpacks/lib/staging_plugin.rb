require 'rubygems'

require 'yaml'
require 'yajl'
require 'erb'
require 'rbconfig'
require 'vcap/logging'

require 'tmpdir' # TODO - Replace this with something less absurd.
# WARNING WARNING WARNING - Only create temp directories when running as a separate process.
# The Ruby stdlib tmpdir implementation is beyond scary in long-running processes.
# You Have Been Warned.

require_relative 'config'

module Buildpacks
  class StagingPlugin

    attr_accessor :source_directory, :destination_directory, :environment_json

    def self.platform_config
      config_path = ENV['PLATFORM_CONFIG']
      YAML.load_file(config_path)
    end

    # Exits the process with a nonzero status if ARGV does not contain valid
    # staging args. If you call this in-process in an app server you deserve your fate.
    def self.validate_arguments!(*args)
      source, dest, env, uid, gid = args
      argfail!(args) unless source && dest && env
      argfail!(args) unless File.directory?(File.expand_path(source))
      argfail!(args) unless File.directory?(File.expand_path(dest))
    end

    def self.argfail!(args)
      puts "Invalid arguments for staging: #{args.inspect}"
      exit 1
    end

    # Loads arguments from a file and instantiates a new instance.
    # @param  arg_filename String  Path to yaml file
    def self.from_file(cfg_filename)
      config = Config.from_file(cfg_filename)

      uid = gid = nil
      if config[:secure_user]
        uid = config[:secure_user][:uid]
        gid = config[:secure_user][:gid]
      end

      validate_arguments!(config[:source_dir],
                          config[:dest_dir],
                          config[:environment],
                          uid,
                          gid)

      self.new(config[:source_dir],
               config[:dest_dir],
               config[:environment],
               uid,
               gid)
    end

    # If you re-implement this in a subclass:
    # A) Do not change the method signature
    # B) Make sure you call 'super'
    #
    # a good subclass impl would look like:
    # def initialize(source, dest, env = nil)
    #   super
    #   whatever_you_have_planned
    #
    # NB: Environment is not what you think it is (better named app_properties?). It is a hash of:
    #   :services  => [service_binding_hash]  # See ServiceBinding#for_staging in cloud_controller/app/models/service_binding.rb
    #   :resources => {                       # See App#resource_requirements or App#limits (they return identical hashes)
    #     :memory => mem limits in MB         # in cloud_controller/app/models/app.rb
    #     :disk   => disk limits in MB
    #     :fds    => fd limits
    #   }
    # end
    def initialize(source_directory, destination_directory, environment = {}, uid=nil, gid=nil)
      @source_directory = File.expand_path(source_directory)
      @destination_directory = File.expand_path(destination_directory)
      @environment = environment
      # Drop privs before staging
      # res == real, effective, saved
      @staging_gid = gid.to_i if gid
      @staging_uid = uid.to_i if uid
    end

    def logger
      @logger ||= \
      begin
        log_file = File.expand_path(File.join(log_dir, "staging.log"))
        FileUtils.mkdir_p(File.dirname(log_file))
        sink_map = VCAP::Logging::SinkMap.new(VCAP::Logging::LOG_LEVELS)
        formatter = VCAP::Logging::Formatter::DelimitedFormatter.new { data }
        sink_map.add_sink(nil, nil, VCAP::Logging::Sink::StdioSink.new(STDOUT, formatter))
        sink_map.add_sink(nil, nil, VCAP::Logging::Sink::FileSink.new(log_file, formatter))
        logger = VCAP::Logging::Logger.new('public_logger', sink_map)
        logger.log_level = ENV["DEBUG"] ? :debug : :info
        logger
      end
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
      if environment[:resources] && environment[:resources][:memory]
        environment[:resources][:memory]
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

    def copy_source_files(dest = nil)
      dest ||= app_dir
      system "cp -a #{File.join(source_directory, "*")} #{dest}"
    end

    def bound_services
      environment[:services] || []
    end

    # Full path to the Ruby we are running under.
    def ruby
      File.join(Config::CONFIG['bindir'], Config::CONFIG['ruby_install_name'])
    end
  end
end
