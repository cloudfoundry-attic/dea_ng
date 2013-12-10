require "yaml"
require "net/ssh"
require "shellwords"

require_relative "process_helpers"
require_relative "local_ip_finder"

require "dea/config"

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
    dea_server.host || raise("unknown dea host")
  end

  def dea_id
    nats.request("dea.status", {
        "limits" => {"mem" => 1, "disk" => 1}
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
    dea_server.pid
  end

  def start_file_server
    @file_server_pid = run_cmd("bundle exec ruby spec/bin/file_server.rb", :debug => true)

    wait_until { is_port_open?("127.0.0.1", 10197) }
  end

  def stop_file_server
    merciless_kill(@file_server_pid) if @file_server_pid
  end

  def file_server_address
    local_ip = LocalIPFinder.new.find

    "#{local_ip.ip_address}:10197"
  end

  def dea_start
    dea_server.start

    Timeout.timeout(10) do
      while true
        begin
          response = nats.request("dea.status", {}, :timeout => 1)
          break if response
        rescue NATS::ConnectError, Timeout::Error
          # Ignore because either NATS is not running, or DEA is not running.
        end
      end
    end
  end

  def dea_stop
    dea_server.stop
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

  def wait_until_instance_evacuating(app_id)
    heartbeat = nats.with_subscription("dea.heartbeat") {}
    heartbeat["droplets"].detect  { |instance| instance.fetch("state") == "EVACUATING" && instance.fetch("droplet") == app_id }
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
    JSON.parse(dea_server.instance_file)
  end

  def dea_server
    @dea_server ||= ENV["LOCAL_DEA"] ? LocalDea.new : RemoteDea.new
  end

  def dea_config
    @dea_config ||= dea_server.config
  end

  class LocalDea
    include ProcessHelpers

    def host
      config["domain"]
    end

    def start
      f = File.new("/tmp/dea.yml", "w")
      f.write(YAML.dump(config))
      f.close

      run_cmd "mkdir -p tmp/logs && bundle exec bin/dea #{f.path} 2>&1 >>tmp/logs/dea.log"
    end

    def stop
      graceful_kill(pid) if pid
    end

    def pid
      File.read(config["pid_filename"]).to_i if !terminated?
    end

    def directory_entries(path)
      Dir.entries(path)
    end

    def config
      @config ||= begin
        config = YAML.load(File.read("config/dea.yml"))
        config["domain"] = LocalIPFinder.new.find.ip_address+".xip.io"
        config
      end
    end

    def evacuate
      Process.kill("USR2", pid)
    end

    def terminated?
      !File.exist?(config["pid_filename"])
    end

    def remove_instance_file
      FileUtils.rm_f(instance_file_path)
    end

    def instance_file
      File.read instance_file_path()
    end

    def instance_file_path
      File.join(config["base_dir"], "db", "instances.json")
    end
  end

  class RemoteDea
    INTEGRATION_CONFIG_FILE =
        File.expand_path("../../../integration/config.yml", __FILE__)

    def host
      integration_config["host"]
    end

    def start
      remote_exec("monit start dea_next")
    end

    def stop
      remote_exec("monit stop dea_next")
    end

    def evacuate
      remote_exec("kill USR2 #{pid}")
    end

    def terminated?
    test_cmd = <<-BASH
      if [ -e #{config["pid_filename"]} ]; then echo "exist"; fi
    BASH
      remote_exec(test_cmd).match("exist").nil?
    end

    def pid
      remote_exec("cat #{config["pid_filename"]}").to_i if !terminated?
    end

    def instance_file
      remote_file(File.join(config["base_dir"], "db", "instances.json"))
    end

    def remove_instance_file
      remote_exec("rm -f #{File.join(config["base_dir"], "db", "instances.json")}")
    end

    def config
      @config ||= begin
        config_yaml = YAML.load(remote_file("/var/vcap/jobs/dea_next/config/dea.yml"))
        Dea::Config.new(config_yaml).tap(&:validate)
      end
    end

    def remote_file(path)
      remote_exec("cat #{path}")
    end

    def directory_entries(path)
      remote_exec("ruby -e \"puts Dir.entries('#{path}')\"").split("\n")
    end

    def integration_config
      @integration_config ||= YAML.load_file(INTEGRATION_CONFIG_FILE)
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

            ch.exec("sudo bash -ic #{Shellwords.escape(cmd)}")

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
  end
end
