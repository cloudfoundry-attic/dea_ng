require "yaml"
require "net/ssh"

require "dea/config"

module DeaHelpers
  INTEGRATION_CONFIG_FILE =
    File.expand_path("../../../integration/config.yml", __FILE__)

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
      raise "Timed out attempting to connect to #{ip}:#{port}"
    end

    return false
  end

  def instance_snapshot(instance_id)
    instances_json["instances"].find do |instance|
      instance["instance_id"] == instance_id
    end
  end

  def dea_host
    integration_config["host"]
  end

  def dea_id
    nats.request("dea.status", {
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

  def dea_pid
    remote_exec("cat #{dea_config["pid_filename"]}").to_i
  end

  def evacuate_dea
    remote_exec("kill -USR2 #{dea_pid}")
    sleep evacuation_delay
  end

  def evacuation_delay
    dea_config["evacuation_delay_secs"]
  end

  def start_file_server
    @file_server_pid = run_cmd("bundle exec ruby spec/bin/file_server.rb", :debug => true)

    wait_until { is_port_open?("127.0.0.1", 9999) }
  end

  def stop_file_server
    graceful_kill(@file_server_pid) if @file_server_pid
  end

  def dea_start
    remote_exec("monit start dea_next")

    Timeout.timeout(10) do
      while true
        begin
          response = nats.request("dea.status", { }, :timeout => 1)
          break if response
        rescue NATS::ConnectError, Timeout::Error
          # Ignore because either NATS is not running, or DEA is not running.
        end
      end
    end
  end

  def dea_stop
    remote_exec("monit stop dea_next")
  end

  def sha1_url(url)
    `curl --silent #{url} | shasum`.split(/\s/).first
  end

  def wait_until_instance_started(app_id, timeout = 60)
    response = nil
    wait_until(timeout) do
      response = nats.request("dea.find.droplet", {
        "droplet" => app_id,
        "states" => ["RUNNING"]
      }, :timeout => 1)
    end
    response
  end

  def wait_until_instance_gone(app_id, timeout = 60)
    wait_until(timeout) do
      res = nats.request("dea.find.droplet", {
        "droplet" => app_id,
      }, :timeout => 1)

      sleep 1

      !res || res["state"] == "CRASHED"
    end
  end

  def wait_until(timeout = 5, &block)
    Timeout.timeout(timeout) do
      loop { return if block.call }
    end
  end

  def nats
    NatsHelper.new(dea_config)
  end

  def instances_json
    JSON.parse(remote_file(File.join(dea_config["base_dir"], "db", "instances.json")))
  end

  def dea_config
    @dea_config ||= begin
      config_yaml = YAML.load(remote_file("/var/vcap/jobs/dea_next/config/dea.yml"))
      Dea::Config.new(config_yaml).tap(&:validate)
    end
  end

  def remote_file(path)
    remote_exec("cat #{path}")
  end

  def remote_exec(cmd)
    host = integration_config["host"]
    username = integration_config["username"]
    password = integration_config["password"]

    Net::SSH.start(host, username, :password => password) do |ssh|
      result = ""

      ssh.open_channel do |ch|
        ch.request_pty do |ch, success|
          raise "could not open pty" unless success

          ch.exec("sudo bash -ic '#{cmd}'")

          ch.on_data do |_, data|
            if data =~ /^\[sudo\] password for #{username}:/
              ch.send_data("#{password}\n")
            else
              result << data
            end
          end
        end
      end

      ssh.loop

      return result
    end
  end

  def integration_config
    @integration_config ||= YAML.load_file(INTEGRATION_CONFIG_FILE)
  end
end
