#!/usr/bin/env ruby
ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../../Gemfile', __FILE__)

require 'rubygems'
require 'bundler/setup'

$LOAD_PATH.unshift(File.expand_path('../../lib', __FILE__))

require 'eventmachine'
require 'yaml'

require 'dea/bootstrap'

require 'win32/daemon'
include Win32

unless ARGV.size == 1
  abort("Usage: dea_winsvc.rb <config path>")
end

class DeaDaemon < Daemon

  def service_init
    begin
      config = YAML.load_file(ARGV[0])

      # Ensure pid file is deleted or else service won't start
      pid_file = config["pid_filename"]
      FileUtils.rm_f(pid_file)

      @bootstrap = Dea::Bootstrap.new(config)
    rescue => e
      abort("ERROR: Failed loading config: #{e}")
    end
  end

  def service_main(*args)

    EM.epoll

    begin
      EM.run {
        @bootstrap.setup
        @bootstrap.start
      }
    rescue => e
      exit!
    end

    @bootstrap.shutdown

    stop_em
  end

  def service_stop
    tries = 0
    while (EM.reactor_running? and tries < 20)
      stop_em
      sleep 1
      tries += 1
    end
    exit! # NB: due to bug(s) in win32-service, this is only way to stop service
  end

  def stop_em
    EM.next_tick { EM.stop }
  end

end

DeaDaemon.mainloop
