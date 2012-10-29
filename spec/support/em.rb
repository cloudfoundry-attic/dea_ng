# coding: UTF-8

require "eventmachine"

module EM
  def self.defers_finished?
    return false if @threadqueue and not @threadqueue.empty?
    return false if @resultqueue and not @resultqueue.empty?
    return false if @threadpool and @threadqueue.num_waiting != @threadpool.size
    return true
  end
end

module Helpers
  def em(options = {})
    raise "no block given" unless block_given?
    timeout = options[:timeout] ||= 1.0

    ::EM.epoll

    ::EM.run {
      quantum = 0.005
      ::EM.set_quantum(quantum * 1000) # Lowest possible timer resolution
      ::EM.set_heartbeat_interval(quantum) # Timeout connections asap
      ::EM.add_timer(timeout) { raise "timeout" }

      # Let threads run on every tick
      ::EM.add_periodic_timer(0.050) { Thread.pass }

      yield
    }
  end

  def done
    raise "reactor not running" if !::EM.reactor_running?

    ::EM.next_tick {
      # Assert something to show a spec-pass
      :done.should == :done
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
