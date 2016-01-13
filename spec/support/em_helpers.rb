# coding: UTF-8

require "eventmachine"

module Helpers
  def with_event_machine(options = {})
    raise "no block given" unless block_given?
    timeout = options[:timeout] ||= 10

    ::EM.epoll if ::EM.epoll?

    ::EM.run do
      quantum = 0.005
      ::EM.set_quantum(quantum * 1000) # Lowest possible timer resolution
      ::EM.set_heartbeat_interval(quantum) # Timeout connections asap
      ::EM.add_timer(timeout) { raise "timeout" }

      yield
    end
  end

  def done
    raise "reactor not running" if !::EM.reactor_running?

    ::EM.next_tick {
      # Assert something to show a spec-pass
      expect(:done).to eq :done
      ::EM.stop_event_loop
    }
  end

  def after_defers_finish
    raise "reactor not running" if !::EM.reactor_running?

    timer = nil

    check = lambda do
      if ::EM.defers_finished?
        timer.cancel

        yield
      end
    end

    timer = ::EM::PeriodicTimer.new(0.01, &check)
  end

  module HttpServer
    attr_writer :blk

    def receive_data(data)
      @blk.call(self, data)
      @blk = nil
    end
  end

  def start_http_server(port, &blk)
    ::EM.start_server("127.0.0.1", port, HttpServer) do |server|
      server.blk = blk
    end
  end
end
