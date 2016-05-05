# coding: UTF-8

require "rspec"

shared_context "bootstrap_setup" do
  stub_nats

  let(:evac_handler) { double('evac_handler', evacuating?: false) }
  let(:shutdown_handler) { double('shutdown_handler', shutting_down?: false) }

  let(:bootstrap) do
    config = {
      "base_dir" => Dir.mktmpdir,
      "intervals" => {
        "advertise" => 1,
        "heartbeat" => 1,
        "router_register_in_seconds" => 20,
      },
      "runtimes" => %w[test1 test2],
      "cc_url" => "cc.example.com",
      "directory_server" => {
        "v2_port" => 23456,
        "protocol" => "http",
        "file_api_port" => 23413412,
      },
      "domain" => "default",
      "logging" => {
        "level" => "debug"
      },
      "nats_servers" => [],
      "pid_filename" => "/var/vcap/jobs/dea_next/pid",
      "warden_socket" => "/var/vcap/jobs/warden/socket",
      "index" => 0,
      "stacks" => [
        {
          "name" => "cflinuxfs2",
          "package_path" => "/tmp/rootfs_cflinuxfs2"
        }
      ],
      "placement_properties" => {
        "zone" => "z1"
      },
      "ssl" => {
        "port" => 8443,
        "key_file" => fixture('/certs/server.key'),
        "cert_file" => fixture('/certs/server.crt')
      },
      "hm9000" => {
        "listener_uri" => "https://127.0.0.1:25432",
        "key_file" => fixture("/certs/hm9000_client.key"),
        "cert_file" => fixture("/certs/hm9000_client.crt"),
        "ca_file" => fixture("/certs/hm9000_ca.crt"),
      }
    }

    bootstrap = Dea::Bootstrap.new(config)
    bootstrap.validate_config

    allow(bootstrap).to receive(:validate_config)

    allow(bootstrap).to receive(:snapshot) { double(:snapshot, :save => nil, :load => nil) }

    allow(bootstrap).to receive(:evac_handler).and_return(evac_handler)
    allow(bootstrap).to receive(:shutdown_handler).and_return(shutdown_handler)

    # No setup (explicitly unstub)
    allow(bootstrap).to receive(:setup_logging)
    allow(bootstrap).to receive(:setup_droplet_registry)
    allow(bootstrap).to receive(:setup_signal_handlers)
    allow(bootstrap).to receive(:setup_directories)
    allow(bootstrap).to receive(:setup_pid_file)
    allow(bootstrap).to receive(:setup_sweepers)
    allow(bootstrap).to receive(:setup_directory_server_v2)
    allow(bootstrap).to receive(:setup_router_client)

    allow(bootstrap).to receive(:start_component)
    allow(bootstrap).to receive(:start_http_server)
    allow(bootstrap).to receive(:start_directory_server)
    allow(bootstrap).to receive(:register_directory_server_v2)
    allow(bootstrap).to receive(:start_finish)

    allow(bootstrap).to receive(:directory_server_v2) { double(:directory_server, :start => nil) }
    bootstrap
  end

  def create_and_register_instance(bootstrap, instance_attributes = {})
    instance_attributes["limits"] = {
      "mem" => 10,
      "disk" => 10,
      "fds" => 16
    }
    instance = Dea::Instance.new(bootstrap, instance_attributes)
    bootstrap.instance_registry.register(instance)
    instance
  end
end
