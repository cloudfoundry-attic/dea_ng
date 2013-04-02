module IntegrationSpecHelpers
  TIMEOUT = 10

  def start_components
    wait_for_dea_stop
    `foreman start 1> /tmp/foreman.stdout.log 2> /tmp/foreman.stderr.log &`
    wait_for_dea_start
  end

  def wait_for_dea_stop
    Timeout::timeout(TIMEOUT) do
      while true
        begin
          break unless NatsHelper.new.connected?
        rescue NATS::ConnectError
          break
        end
      end
    end
  end

  def wait_for_dea_start
    Timeout::timeout(TIMEOUT) do
      while true
        begin
          response = NatsHelper.new.request("dea.status", { }, :timeout => 1)
          break if response
        rescue NATS::ConnectError, Timeout::Error
          # Ignore because either NATS is not running, or DEA is not running.
        end
      end
    end
  end

  def terminate_if_running
    Process.kill("KILL", dea_pid)
  rescue Errno::ESRCH => e
    # Ignore.
  end

  def stop_components
    return unless dea_pid
    terminate_if_running
    terminated = false
    Timeout::timeout(TIMEOUT) do
      while true
        begin
          Process.getpgid(dea_pid)
        rescue Errno::ESRCH
          terminated = true
          break
        end
      end
    end

    # It is expected that foreman will automatically shut down other processes
    # when one of them dies. If DEA does not die gracefully at the end of the
    # tests, then foreman will allow other processes to continue running. We
    # don't want this to happen as this will pollute the test environment.
    msg = "DEA failed to shutdown after delivering SIGTERM at the end of tests."
    raise msg unless terminated
  end
end