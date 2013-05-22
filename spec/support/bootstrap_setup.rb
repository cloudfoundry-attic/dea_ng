# coding: UTF-8

require "rspec"

shared_context "bootstrap_setup" do
  stub_nats

  let(:bootstrap) do
    config = {
      "base_dir" => Dir.mktmpdir,
      "intervals" => {
        "advertise" => 0.01,
        "heartbeat" => 0.01,
      },
      "runtimes" => %w[test1 test2],
      "directory_server" => {
        "v1_port" => 12345,
        "v2_port" => 23456,
      },
      "domain" => "default",
    }

    bootstrap = Dea::Bootstrap.new(config)

    bootstrap.stub(:validate_config)

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
    bootstrap.stub(:directory_server_v2 => mock(:directory_server, :start => nil))
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
