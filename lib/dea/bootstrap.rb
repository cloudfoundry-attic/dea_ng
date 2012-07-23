# coding: UTF-8

require "steno"
require "steno/core_ext"
require "vcap/common"

require "dea/nats"

module Dea
  class Bootstrap
    attr_reader :config

    def initialize(config = {})
      @config = config
    end

    def setup_signal_handlers
      @old_signal_handlers = {}

      %W(TERM INT QUIT USR1 USR2).each do |signal|
        @old_signal_handlers[signal] = ::Kernel.trap(signal) do
          logger.warn "caught SIG#{signal}"
          send("trap_#{signal.downcase}")
        end
      end
    end

    def teardown_signal_handlers
      @old_signal_handlers.each do |signal, handler|
        if handler.respond_to?(:call)
          # Block handler
          ::Kernel::trap(signal, &handler)
        else
          # String handler
          ::Kernel::trap(signal, handler)
        end
      end
    end

    def with_signal_handlers
      begin
        setup_signal_handlers
        yield
      ensure
        teardown_signal_handlers
      end
    end

    def trap_term
    end

    def trap_int
    end

    def trap_quit
    end

    def trap_usr1
    end

    def trap_usr2
    end

    def setup_directories
      %W(db droplets instances tmp).each do |dir|
        FileUtils.mkdir_p(File.join(config[:base_dir], dir))
      end
    end

    def setup_pid_file
      path = config[:pid_filename]

      begin
        pid_file = VCAP::PidFile.new(path, false)
        pid_file.unlink_at_exit
      rescue => err
        logger.error "Cannot create pid file at #{path} (#{err})"
        raise
      end
    end

    def setup_nats
      @nats = Dea::Nats.new(self, config)
    end

    def handle_health_manager_start(message)
    end

    def handle_router_start(message)
    end

    def handle_dea_status(message)
    end

    def handle_dea_directed_start(message)
    end

    def handle_dea_locate(message)
    end

    def handle_dea_stop(message)
    end

    def handle_dea_update(message)
    end

    def handle_dea_find_droplet(message)
    end

    def handle_droplet_status(message)
    end

    private

    def logger
      @logger ||= self.class.logger
    end
  end
end
