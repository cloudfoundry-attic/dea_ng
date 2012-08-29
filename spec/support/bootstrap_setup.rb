# coding: UTF-8

require "rspec"

shared_context "bootstrap_setup" do
  attr_reader :bootstrap
  attr_reader :nats_mock

  before do
    @nats_mock = NatsClientMock.new
    NATS.stub(:connect).and_return(@nats_mock)

    config = {
      "base_dir" => Dir.mktmpdir,
      "intervals" => {
        "advertise" => 0.01,
        "heartbeat" => 0.01,
      },
      "runtimes"  => {
        "test1" => {},
        "test2" => {},
      },
      "directory_server_port" => 8080,
    }

    mock_runtime = mock("Dea::Runtime")
    mock_runtime.stub(:validate)
    Dea::Runtime.stub(:new).and_return(mock_runtime)

    @bootstrap = Dea::Bootstrap.new(config)

    # No config validation
    @bootstrap.stub(:validate_config)

    # No snapshotting
    @bootstrap.stub(:save_snapshot)
    @bootstrap.stub(:load_snapshot)

    # No setup (explicitly unstub)
    @bootstrap.stub(:setup_logging)
    @bootstrap.stub(:setup_runtimes)
    @bootstrap.stub(:setup_droplet_registry)
    @bootstrap.stub(:setup_resource_manager)
    @bootstrap.stub(:setup_instance_registry)
    @bootstrap.stub(:setup_signal_handlers)
    @bootstrap.stub(:setup_directories)
    @bootstrap.stub(:setup_pid_file)
    @bootstrap.stub(:setup_sweepers)
    @bootstrap.stub(:setup_directory_server)
    @bootstrap.stub(:setup_nats)
    @bootstrap.stub(:setup_router_client)

    # No start (explicitly unstub)
    @bootstrap.stub(:start_component)
    @bootstrap.stub(:start_nats)
    @bootstrap.stub(:start_directory_server)
    @bootstrap.stub(:start_finish)
  end

  before do
    # Setup that is always needed
    @bootstrap.unstub(:setup_runtimes)
    @bootstrap.unstub(:setup_resource_manager)
    @bootstrap.unstub(:setup_instance_registry)
    @bootstrap.unstub(:setup_nats)

    # Start that is always needed
    @bootstrap.unstub(:start_nats)
  end

  def create_and_register_instance(bootstrap, instance_attributes = {})
    instance = Dea::Instance.new(bootstrap, instance_attributes)
    bootstrap.instance_registry.register(instance)
    instance
  end
end
