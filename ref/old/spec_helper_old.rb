$LOAD_PATH.unshift(File.expand_path("../../lib", __FILE__))

require "eventmachine"
require "fiber"
require "nats/client"
require "tmpdir"

require "vcap/common"
require "vcap/dea"
require "vcap/logging"
require 'em_fiber_wrap'

if ENV["VCAP_TEST_SHOW_LOGS"]
  VCAP::Logging.setup_from_config({})
else
  VCAP::Logging.setup_from_config(:file => "/dev/null")
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

def spec_asset_path(*parts)
  File.expand_path(File.join("../assets", *parts), __FILE__)
end

def create_test_droplet(droplet_path)
  test_droplet_glob = spec_asset_path('test_app', '*')
  unless system("tar -czf #{droplet_path} #{test_droplet_glob}")
    raise "Failed creating test droplet"
  end
end

shared_context :nats do
  before(:all) do
    port = VCAP.grab_ephemeral_port
    base_dir = Dir.mktmpdir
    @nats_config = {
      :port     => port,
      :base_dir => base_dir,
      :pid_file => File.join(base_dir, "nats.pid"),
      :uri => "nats://localhost:#{port}",
    }

    # Start nats
    cmd = "bundle exec nats-server"             \
          + " --port #{@nats_config[:port]}"    \
          + " --pid #{@nats_config[:pid_file]}" \
          + " --daemonize"
    puts `#{cmd}`
    $?.exitstatus.should == 0

    # Wait for nats to be ready. Raises an error on timeout
    em do
      NATS.connect(:uri => @nats_config[:uri]) do
        EM.stop
      end
    end
  end

  def nats(opts={}, &blk)
    em(opts) do
      NATS.start(:uri => @nats_config[:uri]) do
        blk.call
      end
    end
  end

  def f_wait_for_dea
    f = Fiber.current
    NATS.subscribe('dea.announce') do
      f.resume
    end
    Fiber.yield
  end

  def f_nats_request(subject, data=nil, opts={})
    f = Fiber.current
    NATS.request(subject, Yajl::Encoder.encode(data), opts) do |msg|
      reply = Yajl::Parser.parse(msg)
      f.resume(reply)
    end
    Fiber.yield
  end

  after(:all) do
    if @nats_config && File.exist?(@nats_config[:pid_file])
      pid = File.read(@nats_config[:pid_file]).chomp
      `kill -9 #{pid}`
      FileUtils.rm_f(@nats_config[:pid_file])
    end
  end
end

shared_context :warden do
  let(:warden_socket_path) { ENV['VCAP_WARDEN_SOCKET_PATH'] }
end

RSpec.configure do |config|
  unless ENV['VCAP_WARDEN_SOCKET_PATH']
    config.filter_run_excluding :needs_warden => true
  end
end
