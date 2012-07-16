require "eventmachine"

module Helpers
  def em(options = {})
    raise "no block given" unless block_given?
    timeout = options[:timeout] ||= 0.1

    ::EM.run {
      expect do
        quantum = 0.005
        ::EM.set_quantum(quantum * 1000) # Lowest possible timer resolution
        ::EM.set_heartbeat_interval(quantum) # Timeout connections asap
        ::EM.add_timer(timeout) { raise "timeout" }
        yield
      end.to_not raise_error
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
