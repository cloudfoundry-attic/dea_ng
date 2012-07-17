require "steno"
require "steno/core_ext"

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

    private

    def logger
      @logger ||= self.class.logger
    end
  end
end
