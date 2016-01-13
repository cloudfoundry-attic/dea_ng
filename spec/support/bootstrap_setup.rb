# coding: UTF-8

require "rspec"

shared_context "bootstrap_setup" do
  stub_nats

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
      },
      "domain" => "default",
      "logging" => {
        "level" => "debug"
      },
      "nats_servers" => [],
      "pid_filename" => "/var/vcap/jobs/dea_next/pid",
      "warden_socket" => "/var/vcap/jobs/warden/socket",
      "index" => 0,
      "directory_server" => {
        "protocol" => "https",
        "v2_port" => 20230303,
        "file_api_port" => 23413412,
      },
      "stacks" => [
        {
          "name" => "cflinuxfs2",
          "package_path" => "/tmp/rootfs_cflinuxfs2"
        }
      ],
      "placement_properties" => {
        "zone" => "z1"
      }
    }

    bootstrap = Dea::Bootstrap.new(config)
    bootstrap.validate_config

    bootstrap.stub(:validate_config)

    bootstrap.stub(:snapshot) { double(:snapshot, :save => nil, :load => nil) }

    # No setup (explicitly unstub)
    bootstrap.stub(:setup_logging)
    bootstrap.stub(:setup_droplet_registry)
    bootstrap.stub(:setup_signal_handlers)
    bootstrap.stub(:setup_directories)
    bootstrap.stub(:setup_pid_file)
    bootstrap.stub(:setup_sweepers)
    bootstrap.stub(:setup_directory_server)
    bootstrap.stub(:setup_directory_server_v2)
    bootstrap.stub(:setup_router_client)

    bootstrap.stub(:start_component)
    bootstrap.stub(:start_directory_server)
    bootstrap.stub(:register_directory_server_v2)
    bootstrap.stub(:start_finish)

    bootstrap.stub(:setup_directory_server_v2)
    bootstrap.stub(:directory_server_v2 => double(:directory_server, :start => nil))
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
