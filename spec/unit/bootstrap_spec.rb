# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"
require "dea/instance"

describe Dea::Bootstrap do
  stub_nats
  include_context "tmpdir"

  before do
    @config = {
      "base_dir" => tmpdir,
      "directory_server" => {
        "v1_port" => 12345,
      },
      "domain" => "default"
    }
  end

  subject(:bootstrap) do
    Dea::Bootstrap.new(@config)
  end

  let(:nats_client_mock) do
    nats_client_mock = mock("nats_client").as_null_object
    nats_client_mock.stub(:flush) { |&blk| blk.call }
    nats_client_mock
  end

  describe "logging setup" do
    after { bootstrap.setup_logging }

    it "should use a file sink when specified" do
      @config = { "logging" => { "file" => File.join(tmpdir, "out.log") } }

      Steno.should_receive(:init).with do |config|
        config.sinks.any? do |sink|
          sink.kind_of?(Steno::Sink::IO)
        end.should == true
      end
    end

    it "should use a syslog sink when specified" do
      @config = { "logging" => { "syslog" => "ident" } }

      Steno.should_receive(:init).with do |config|
        config.sinks.any? do |sink|
          sink.kind_of?(Steno::Sink::Syslog)
        end.should == true
      end
    end

    it "should set the default log level when specified" do
      @config = { "logging" => { "level" => "debug" } }

      Steno.should_receive(:init).with do |config|
        config.default_log_level.should == :debug
      end
    end
  end

  describe "droplet registry setup" do
    before { bootstrap.setup_droplet_registry }

    it "should create a new droplet registry" do
      bootstrap.droplet_registry.should be_a(Dea::DropletRegistry)
      bootstrap.droplet_registry.base_dir.should == File.join(@config["base_dir"], "droplets")
    end
  end

  describe "instance registry setup" do
    before { bootstrap.setup_instance_registry }

    it "should create a new instance registry" do
      bootstrap.instance_registry.should be_a(Dea::InstanceRegistry)
    end
  end

  describe "staging task registry setup" do
    it "creates staging task registry" do
      expect {
        bootstrap.setup_staging_task_registry
      }.to change { bootstrap.staging_task_registry }.from(nil)

      bootstrap.staging_task_registry.tap do |r|
        r.should be_a(Dea::StagingTaskRegistry)
      end
    end
  end

  describe "signal handlers" do
    def send_signal(signal)
      Process.kill(signal, Process.pid)

      # Wait for the signal to arrive
      sleep 0.05
    end

    def test_signal(signal)
      bootstrap.with_signal_handlers do
        bootstrap.should_receive("trap_#{signal.downcase}")
        send_signal(signal)
      end
    end

    %W(TERM INT QUIT USR1 USR2).each do |signal|
      it "should trap SIG#{signal}" do
        test_signal(signal)
      end
    end

    it "should restore original handler" do
      original_handler_called = 0
      ::Kernel.trap("TERM") do
        original_handler_called += 1
      end

      # This should not call the original handler
      test_signal("TERM")
      original_handler_called.should == 0

      # This should call the original handler
      send_signal("TERM")
      original_handler_called.should == 1
    end
  end

  describe "directory setup" do
    before do
      bootstrap.setup_directories
    end

    %W(db droplets instances tmp).each do |dir|
      it "should create '#{dir}'" do
        File.directory?(File.join(tmpdir, dir)).should be_true
      end
    end
  end

  describe "pid file setup" do
    it "should create a pid file" do
      pid_filename = File.join(tmpdir, "pid")
      bootstrap = Dea::Bootstrap.new("pid_filename" => pid_filename)
      bootstrap.setup_pid_file

      pid = File.read(pid_filename).chomp.to_i
      pid.should == Process.pid
    end

    it "should raise when it can't create the pid file" do
      expect do
        pid_filename = File.join(tmpdir, "doesnt_exist", "pid")
        bootstrap = Dea::Bootstrap.new("pid_filename" => pid_filename)
        bootstrap.setup_pid_file
      end.to raise_error
    end
  end

  describe "shutdown" do
    before do
      bootstrap.setup_signal_handlers
      bootstrap.setup_instance_registry
      bootstrap.setup_staging_task_registry
      bootstrap.setup_router_client
      bootstrap.setup_directory_server_v2
    end

    context "when instances are registered" do
      before do
        bootstrap.instance_registry.register(Dea::Instance.new(bootstrap, {}))
        bootstrap.instance_registry.register(Dea::Instance.new(bootstrap, {}))
      end

      it "stops registered instances" do
        bootstrap.stub(:nats).and_return(nats_client_mock)

        bootstrap.instance_registry.each do |instance|
          instance.should_receive(:stop).and_call_original
        end

        # Accommodate the extra terminate call because we don't really
        # exit the test when we terminate.
        bootstrap.should_receive(:terminate).twice

        bootstrap.shutdown
      end
    end

    context "when staging tasks are registered" do
      before do
        bootstrap.staging_task_registry.register(Dea::StagingTask.new(bootstrap, nil, {}))
        bootstrap.staging_task_registry.register(Dea::StagingTask.new(bootstrap, nil, {}))
      end

      it "stops registered tasks" do
        bootstrap.stub(:nats).and_return(nats_client_mock)

        bootstrap.staging_task_registry.each do |task|
          task.should_receive(:stop).and_call_original
        end

        # Accommodate the extra terminate call because we don't really
        # exit the test when we terminate.
        bootstrap.should_receive(:terminate).twice

        bootstrap.shutdown
      end
    end

    it "should stop and flush nats" do
      nats_mock = mock("nats")
      nats_mock.should_receive(:stop)
      nats_mock.should_receive(:client).and_return(nats_client_mock)
      nats_mock.should_receive(:publish) do |subject, message|
        subject.should == "router.unregister"

        message.should be_an_instance_of Hash
        message["host"].should == bootstrap.local_ip
        message["port"].should == bootstrap.config["directory_server"]["v2_port"]
        message["uris"].size.should == 1
        message["uris"][0].should match /.*\.#{bootstrap.config["domain"]}$/
      end

      nats_client_mock.should_receive(:flush)

      bootstrap.stub(:nats).and_return(nats_mock)

      # Don't want to exit tests, but ensure that we receive terminate exactly
      # once.
      bootstrap.should_receive(:terminate)

      bootstrap.shutdown
    end
  end

  describe "evacuation" do
    before :each do
      bootstrap.setup_signal_handlers
      bootstrap.setup_instance_registry
    end

    it "should send an exited message for each instance" do
      instance = Dea::Instance.new(bootstrap, "application_id" => 0)
      instance.state = Dea::Instance::State::RUNNING
      bootstrap.instance_registry.register(instance)

      # For shutdown delay
      EM.stub(:add_timer)

      bootstrap.
        should_receive(:send_exited_message).
        with(instance, Dea::Bootstrap::EXIT_REASON_EVACUATION)

      bootstrap.should_receive(:stop_sweepers)
      bootstrap.evacuate
    end

    it "should call shutdown after some time" do
      bootstrap.stub(:config).and_return({ "evacuation_delay_secs" => 0.2 })

      shutdown_timestamp = nil
      bootstrap.stub(:shutdown) do
        shutdown_timestamp = Time.now
        EM.stop
      end

      start = Time.now
      em(:timeout => 1) do
        bootstrap.evacuate
      end

      shutdown_timestamp.should_not be_nil
      (shutdown_timestamp - start).should be_within(0.05).of(0.2)
    end
  end

  describe "#reap_unreferenced_droplets" do
    let(:droplet_registry) do
      droplet_registry = {}
      ["a", "b", "c", "d"].each do |sha|
        droplet_registry[sha] = mock("droplet_#{sha}")
        droplet_registry[sha].stub(:destroy)
      end
      droplet_registry
    end

    let(:instance_registry) do
      instance_registry = []
      ["a", "b"].each do |sha|
        instance_registry << mock("instance_#{sha}")
        instance_registry.last.stub(:droplet_sha1).and_return(sha)
      end
      instance_registry
    end

    let(:unreferenced_shas) do
      droplet_registry.keys - instance_registry.map(&:droplet_sha1)
    end

    let(:referenced_shas) do
      instance_registry.map(&:droplet_sha1)
    end

    before do
      bootstrap.stub(:instance_registry).and_return(instance_registry)
      bootstrap.stub(:droplet_registry).and_return(droplet_registry)
    end

    it "should delete any unreferenced droplets from the registry" do
      bootstrap.reap_unreferenced_droplets
      bootstrap.droplet_registry.keys.should == referenced_shas
    end

    it "should destroy any unreferenced droplets" do
      unreferenced_shas.each do |sha|
        droplet_registry[sha].should_receive(:destroy)
      end
      bootstrap.reap_unreferenced_droplets
    end
  end

  describe "start_component" do
    it "adds stacks to varz" do
      @config["stacks"] = ["Linux"]

      bootstrap.stub(:nats).and_return(nats_client_mock)

      # stubbing this to avoid a runtime exception
      VCAP::Component.stub(:register)
      VCAP::Component.stub(:uuid => 1)

      bootstrap.start_component

      VCAP::Component.varz[:stacks].should == ["Linux"]
    end
  end

  describe "#start_nats" do
    before do
      EM.stub(:add_periodic_timer)
      bootstrap.stub(:uuid => "unique-dea-id")
      bootstrap.setup_nats
    end

    it "starts nats" do
      bootstrap.nats.should_receive(:start)
      bootstrap.start_nats
    end

    it "sets up staging responder to respond to staging requests" do
      bootstrap.setup_staging_task_registry
      bootstrap.setup_directory_server_v2
      bootstrap.start_nats

      responder = bootstrap.responders.detect { |r| r.is_a?(Dea::Responders::Staging) }
      responder.should_not be_nil

      responder.tap do |r|
        r.nats.should be_a(Dea::Nats)
        r.dea_id.should be_a(String)
        r.bootstrap.should == bootstrap
        r.staging_task_registry.should be_a(Dea::StagingTaskRegistry)
        r.dir_server.should be_a(Dea::DirectoryServerV2)
        r.config.should be_a(Dea::Config)
      end
    end

    it "sets up dea locator responder to respond to 'dea.locate' and send out 'dea.advertise'" do
      bootstrap.setup_resource_manager
      bootstrap.start_nats

      responder = bootstrap.responders.detect { |r| r.is_a?(Dea::Responders::DeaLocator) }
      responder.should_not be_nil

      responder.tap do |r|
        r.nats.should be_a(Dea::Nats)
        r.dea_id.should be_a(String)
        r.resource_manager.should be_a(Dea::ResourceManager)
        r.config.should be_a(Dea::Config)
      end
    end

    it "sets up staging locator responder to respond to 'staging.locate' and send out 'staging.advertise'" do
      bootstrap.setup_resource_manager
      bootstrap.start_nats

      responder = bootstrap.responders.detect { |r| r.is_a?(Dea::Responders::StagingLocator) }
      responder.should_not be_nil

      responder.tap do |r|
        r.nats.should be_a(Dea::Nats)
        r.dea_id.should be_a(String)
        r.resource_manager.should be_a(Dea::ResourceManager)
        r.config.should be_a(Dea::Config)
      end
    end
  end

  describe "#start_finish" do
    before { EM.stub(:add_periodic_timer => nil, :add_timer => nil) }

    before do
      bootstrap.stub(:uuid => "unique-dea-id")
      bootstrap.setup_nats
      bootstrap.setup_directory_server
      bootstrap.setup_instance_registry
      bootstrap.setup_staging_task_registry
      bootstrap.setup_resource_manager
      bootstrap.start_nats
    end

    it "advertises dea" do
      Dea::Responders::DeaLocator.any_instance.should_receive(:advertise)
      bootstrap.start_finish
    end

    it "advertises staging" do
      Dea::Responders::StagingLocator.any_instance.should_receive(:advertise)
      bootstrap.start_finish
    end
  end

  describe "#evacuate" do
    before { EM.stub(:add_periodic_timer => nil, :add_timer => nil) }

    context "when advertising/locating was set up" do
      before do
        bootstrap.stub(:uuid => "unique-dea-id")
        bootstrap.setup_nats
        bootstrap.setup_resource_manager
        bootstrap.start_nats
      end

      it "stops dea advertising/locating" do
        Dea::Responders::DeaLocator.any_instance.should_receive(:stop)
        bootstrap.evacuate
      end

      it "stops staging advertising/locating" do
        Dea::Responders::StagingLocator.any_instance.should_receive(:stop)
        bootstrap.evacuate
      end
    end

    context "when advertising/locating was not set up" do
      it "does not stop dea locator" do
        Dea::Responders::DeaLocator.any_instance.should_not_receive(:stop)
        bootstrap.evacuate
      end

      it "does not stop staging locator" do
        Dea::Responders::StagingLocator.any_instance.should_not_receive(:stop)
        bootstrap.evacuate
      end
    end
  end

  describe "creating an instance" do
    subject(:instance) do
      bootstrap.setup_instance_registry
      bootstrap.create_instance(valid_instance_attributes.merge(extra_attributes))
    end

    context "when the resource manager can not reserve space for the app" do
      before do
        bootstrap.instance_variable_set(:@logger, logger)
        bootstrap.instance_variable_set(:@resource_manager, resource_manager)
      end

      let(:logger) { double(:mock_logger) }
      let(:resource_manager) do
        manager = double(:resource_manager)
        manager.stub(:could_reserve?).with(1, 2).and_return(false)
        manager
      end
      let(:extra_attributes) { {"limits" => {"mem" => 1, "disk" => 2, "fds" => 3}} }

      it 'should log and error and return nil' do
        logger.should_receive(:error).with(/not enough resources available/)
        instance.should be_nil
      end
    end

    context "when the resource manager can reserve space for the app" do
      before do
        bootstrap.instance_variable_set(:@logger, logger)
        bootstrap.instance_variable_set(:@resource_manager, resource_manager)
      end

      let(:logger) { double(:mock_logger) }
      let(:resource_manager) do
        manager = double(:resource_manager)
        manager.stub(:could_reserve?).with(1, 2).and_return(true)
        manager
      end
      let(:extra_attributes) { {"limits" => {"mem" => 1, "disk" => 2, "fds" => 3}} }

      it 'should create the instance' do
        logger.should_not_receive(:error)
        logger.should_not_receive(:warn)

        instance.should be_a(::Dea::Instance)
      end
    end
  end
end
