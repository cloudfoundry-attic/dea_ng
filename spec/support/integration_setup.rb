module IntegrationSetup
  def start_nats
    before(:all) { @nats_pid = run_cmd("nats-server") }
    before(:all) { check_process_alive!(:nats, @nats_pid, :sleep => 0.5) }
    after(:all) { graceful_kill(:nats, @nats_pid) }
  end

  def start_dea
    before(:all) { @dea_pid = run_cmd("bin/dea config/dea.yml") }
    before(:all) { check_process_alive!(:dea, @dea_pid, :sleep => 2) }
    after(:all) { graceful_kill(:dea, @dea_pid) }
  end

  def start_directory_server
    before(:all) do
      @directory_server_pid = begin
        run_with_go("go/bin/go install runner", :wait => true)
        run_with_go("go/bin/runner -conf config/dea.yml")
      end
    end

    before(:all) { check_process_alive!(:directory_server, @directory_server_pid, :sleep => 2) }
    after(:all) { graceful_kill(:directory_server, @directory_server_pid) }
  end
end

module IntegrationHelpers
  def run_cmd(cmd, options={})
    project_path = File.join(File.dirname(__FILE__), "../..")
    spawn_opts = {:chdir => project_path, :out => "/dev/null", :err => "/dev/null"}

    Process.spawn(cmd, spawn_opts).tap do |pid|
      if options[:wait]
        Process.wait(pid)
        raise "`#{cmd}` exited with #{$?}" unless $?.success?
      end
    end
  end

  def run_with_go(cmd, options={})
    run_cmd("PATH=$PATH:/usr/local/go/bin #{cmd}", options)
  end

  def check_process_alive!(name, pid, options={})
    sleep(options[:sleep]) if options[:sleep]
    raise "Process #{name} with pid #{pid} is not alive." \
      unless process_alive?(@nats_pid)
  end

  def graceful_kill(name, pid)
    Process.kill("TERM", pid)
    Timeout.timeout(1) do
      while process_alive?(pid) do
      end
    end
  rescue Timeout::Error
    Process.kill("KILL", pid)
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end

RSpec.configure do |rspec_config|
  rspec_config.include(IntegrationHelpers, :type => :integration)
  rspec_config.extend(IntegrationSetup, :type => :integration)
end
