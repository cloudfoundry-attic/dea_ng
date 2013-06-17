require "yaml"

module DeaHelpers
  def is_port_open?(ip, port)
    begin
      Timeout::timeout(5) do
        begin
          s = TCPSocket.new(ip, port)
          s.close
          return true
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
          return false
        end
      end
    rescue Timeout::Error
      p "Timed out attempting to connect to #{ip}:#{port}"
    end

    return false
  end

  def snapshot_path
    File.join(dea_config["base_dir"], "db", "instances.json")
  end

  def instance_snapshot(instance_id)
    instances_config = YAML.load_file(snapshot_path)
    instances_config["instances"].find { |instance| instance["instance_id"] == instance_id }
  end

  def dea_id
    nats.request("dea.discover", {
      "limits" => { "mem" => 1, "disk" => 1 }
    })["id"]
  end

  def dea_memory
    # Use NATS to locate the only DEA running as part of this integration test.
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

  def sha1_url(url)
    `curl --silent #{url} | sha1sum`.split(/\s/).first
  end

  def wait_until_instance_started(app_id, timeout = 5)
    wait_until(timeout) do
      nats.request("dea.find.droplet", {
        "droplet" => app_id,
        "states" => ["RUNNING"]
      }, :timeout => 1)
    end
  end

  def wait_until_instance_gone(app_id, timeout = 5)
    wait_until(timeout) do
      res = nats.request("dea.find.droplet", {
        "droplet" => app_id,
      }, :timeout => 1)
      !res || res["state"] == "CRASHED"
    end
  end

  def wait_until(timeout = 5, &block)
    Timeout.timeout(timeout) do
      loop { return if block.call }
    end
  end

  private

  def nats
    NatsHelper.new
  end
end