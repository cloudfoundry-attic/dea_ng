# coding: UTF-8

require "rspec"

shared_context "bootstrap_setup" do
  attr_reader :bootstrap
  attr_reader :nats_mock

  before :each do
    @nats_mock = NatsClientMock.new({})
    NATS.stub(:connect).and_return(@nats_mock)

    config = {
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

    mock_runtime = mock("runtime")
    mock_runtime.should_receive(:validate).twice()
    Dea::Runtime.stub(:new).and_return(mock_runtime)

    @bootstrap = Dea::Bootstrap.new(config)
    @bootstrap.setup_instance_registry
    @bootstrap.setup_runtimes
    @bootstrap.setup_router_client
    @bootstrap.setup_resource_manager
    @bootstrap.setup_directory_server
    @bootstrap.setup_nats
    @bootstrap.nats.start
  end

  def create_and_register_instance(bootstrap, inst_opts = {})
    instance = Dea::Instance.new(bootstrap, inst_opts)
    bootstrap.instance_registry.register(instance)
    instance
  end
end
