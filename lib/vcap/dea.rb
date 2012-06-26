$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), 'dea'))

require 'vcap/common'
require 'vcap/logging'
require 'vcap/component'

require 'vcap/dea/handler'
require 'vcap/dea/resource_tracker'
require 'vcap/dea/server'
require 'vcap/dea/config'
require 'vcap/dea/version'
require 'vcap/dea/warden_env'
require 'vcap/dea/em_fiber_wrap'
require 'vcap/dea/debug_formatter'

module VCAP
  module Dea
    class << self
      attr_accessor :config

      def init(config_file)
         puts "Initializing DEA."
        begin
          config = VCAP::Dea::Config.from_file(config_file)
        rescue VCAP::JsonSchema::ValidationError => ve
          puts "ERROR: There was a problem validating the supplied config: #{ve}"
          exit 1
        rescue => e
          puts "ERROR: Failed loading config from file '#{config_file}': #{e}"
          exit 1
        end
        @config = config
      end

      def start_server!
        VCAP::Logging.setup_from_config(config[:logging])
        @logger = VCAP::Logging.logger('dea')
        #XXX@logger = Logger.new(STDOUT)
        #XXX@logger.formatter = DebugFormatter.new
        @logger.info "Starting VCAP DEA version #{VCAP::Dea::VERSION}, pid: #{Process.pid}."
        sub_dirs = %w[tmp droplets db instances]
        base_dir = @config[:base_dir]
        setup_pidfile
        setup_directories(base_dir, sub_dirs)
        clean_directories(sub_dirs) if @config[:reset_at_startup]
        params = @config.dup
        params[:directories] = @directories
        nats_uri = @config[:nats_uri]
        @logger.info "Using #{nats_uri}."
        handler = VCAP::Dea::Handler.new(params, @logger)
        @server = VCAP::Dea::Server.new(nats_uri, handler, @logger)

        VCAP::Dea::WardenEnv.set_warden_socket_path(@config[:warden_socket_path])
        check_warden

        ['TERM', 'INT', 'QUIT'].each { |s| trap(s) { @server.shutdown() } }
        trap('USR2') { @server.evacuate_apps_then_quit() }
        trap('USR1') { @logger.error("Got SIGUSR1 - don't know what that means, SIGUSR2 to evactuate apps, SIGINT to shutdown.")}
        at_exit { clean_directories(%w[tmp]) } #prevent storage leaks.
        EventMachine.run {
          @server.start
          handler.start_file_viewer
        }
      end

      def check_warden
        begin
          em_fiber_wrap {
            env = VCAP::Dea::WardenEnv.new(@logger)
            env.create_container
            env.run("echo foo > foo")
            env.destroy!
          }
        rescue => e
          @logger.warn "warden sanity check failed, make sure warden is running!"
          @logger.error e.message
          @logger.error e.backtrace.join("\n")
          exit 1
        end
        @logger.info "warden sanity check passed..."
      end

      def purge_directory!(path)
        @logger.info("purging #{path}")
        FileUtils.rm_rf Dir.glob("#{path}/*"), :secure => true
      end

      def clean_directories(sub_dirs)
        sub_dirs.each { |name|
          path = @directories[name]
          purge_directory!(path)
        }
      end

      def add_directory(base_dir, name)
        @directories[name] = File.join(base_dir, name)
      end

      def setup_directories(base_dir, sub_dirs)
        @directories = Hash.new
        sub_dirs.each {|name|
          add_directory(base_dir, name)
        }
        @directories.each { |name, path|
          unless Dir.exists?(path)
            @logger.info("Installing #{path}")
            FileUtils.mkdir_p(path)
          end
        }
      end

      def setup_pidfile
        path = @config[:pid_filename]
        begin
          pid_file = VCAP::PidFile.new(path)
          pid_file.unlink_at_exit
        rescue => e
          @logger.error "ERROR: Can't create dea pid file #{path}"
          exit 1
        end
      end
    end
  end
end

