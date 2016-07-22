require "yaml"
require "net/ssh"
require "shellwords"

require_relative "process_helpers"

require "dea/config"

module DeaHelpers
  def is_port_open?(ip, port)
    begin
      Timeout::timeout(15) do
        begin
          s = TCPSocket.new(ip, port)
          s.close
          return true
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET
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

  def dea_memory
    # Use NATS to locate the only DEA running as part of this integration test.
    nats.with_nats do
      NATS.subscribe("dea.advertise", :do_not_track_subscription => true) do |msg|
        return Yajl::Parser.parse(msg)["available_memory"] if msg
      end
    end
  end

  def dea_pid
    dea_server.pid
  end

  def start_file_server
    local_ip = Dea.local_ip
    `sudo /sbin/iptables -I INPUT 2 -j ACCEPT -p tcp --dport 10197 -d #{local_ip}`
    @file_server_pid = run_cmd("bundle exec ruby spec/bin/file_server.rb", :debug => true)
    sleep 1
    wait_until { is_port_open?(local_ip, 10197) }
  end

  def stop_file_server
    iptable_rule = `sudo /sbin/iptables -S INPUT | grep 10197 | sed -e 's/^-A/-D/'`
    iptable_rule.chomp
    iptable_rule.each_line do |rule|
      `sudo /sbin/iptables #{rule}` unless rule.empty?
    end
    merciless_kill(@file_server_pid) if @file_server_pid
  end

  def file_server_address
    local_ip = Dea.local_ip

    "#{local_ip}:10197"
  end

  def dea_start(extra_config={})
    dea_server.start(extra_config)

    Timeout.timeout(10) do
      begin
        advertise = nats.with_subscription("dea.advertise") {}
        puts "dea server started, dea.advertise received"
      rescue NATS::ConnectError, Timeout::Error
        # Ignore because either NATS is not running, or DEA is not running.
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
    uri = URI.join(dea_config['hm9000']['listener_uri'], "/dea/heartbeat")

    heartbeat = ""
    with_event_machine(:timeout => 10) do
      http_server =
        Thin::Server.new('0.0.0.0', uri.port, lambda { |env|
          heartbeat = Yajl::Parser.parse(env['rack.input'])
          if heartbeat["droplets"].detect  { |instance| instance.fetch("state") == "EVACUATING" && instance.fetch("droplet") == app_id }
            done
          end

          [202, {}, ''] }, { signals: false })

      http_server.ssl = true
      http_server.ssl_options = {
        private_key_file: fixture('/certs/hm9000_server.key'),
        cert_chain_file: fixture('/certs/hm9000_server.crt'),
        verify_peer: true,
      }

      http_server.start
    end

    return heartbeat["droplets"].detect  { |instance| instance.fetch("state") == "EVACUATING" && instance.fetch("droplet") == app_id }
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
    @dea_server ||= LocalDea.new
  end

  def dea_config
    @dea_config ||= dea_server.config
  end

  class LocalDea
    include ProcessHelpers

    def host
      config["domain"]
    end

    def start(extra_config = {})
      f = File.new("/tmp/dea.yml", "w")
      f.write(YAML.dump(config.merge(extra_config)))
      f.close

      @running = true
      run_cmd "mkdir -p tmp/logs && bundle exec bin/dea #{f.path} 1>tmp/logs/dea.log 2>tmp/logs/dea.err.log"
    end

    def stop
      @running = false
      graceful_kill(pid) if pid
    end

    def running?
      @running
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
        config["domain"] = Dea.local_ip
        config["intervals"] = {
          "advertise" => 1
        }
        config["hm9000"] = {
          'listener_uri' => "https://127.0.0.1:3569",
          'key_file' => fixture('/certs/hm9000_client.key'),
          'cert_file' => fixture("/certs/hm9000_client.crt"),
          'ca_file' => fixture("/certs/hm9000_ca.crt"),
        }
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
end
