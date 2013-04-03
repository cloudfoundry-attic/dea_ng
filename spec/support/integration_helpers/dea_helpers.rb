require "yaml"

module DeaHelpers
  def dea_id
    nats.request("dea.discover", {
      "limits" => { "mem" => 1, "disk" => 1 }
    })["id"]
  end

  def dea_memory
    response = nats.with_subscription("dea.advertise") do
      nats.publish("dea.locate", {}, :async => true)
    end

    response["available_memory"]
  end

  def dea_config
    @config ||= YAML.load(File.read("config/dea.yml"))
  end

  def dea_pid
    File.read(dea_config["pid_filename"]).to_i
  rescue Errno::ENOENT
    # File was removed
  end

  def dea_start
    run_cmd("bundle exec bin/dea config/dea.yml 2>&1 >>tmp/logs/dea.log")
    Timeout::timeout(10) do
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

  def dea_stop
    graceful_kill(dea_pid)
  end

  private

  def nats
    NatsHelper.new
  end
end