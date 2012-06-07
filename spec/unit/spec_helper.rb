$LOAD_PATH.unshift(File.expand_path("../../../lib/vcap/dea", __FILE__))
require 'eventmachine'
require 'em_fiber_wrap'

def warden_is_alive?
  if File.exists? '/tmp/warden.sock'
    begin
      UNIXSocket.new('/tmp/warden.sock')
      return true
    rescue => e
    end
  end
  false
end

RSpec.configure do |c|
  # declare an exclusion filter
   unless warden_is_alive?
     c.filter_run_excluding :needs_warden => true
   end
end

def em(options = {})
  raise "no block given" unless block_given?
  timeout = options[:timeout] ||= 1.0

  ::EM.run {
    quantum = 0.005
    ::EM.set_quantum(quantum * 1000) # Lowest possible timer resolution
    ::EM.set_heartbeat_interval(quantum) # Timeout connections asap
    ::EM.add_timer(timeout) { raise "timeout" }
    yield
  }
end
