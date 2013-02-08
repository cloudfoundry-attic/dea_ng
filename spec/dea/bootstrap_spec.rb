# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"
require "dea/instance"

describe Dea::Bootstrap do
  include_context "tmpdir"

  before do
    @config = {
      "base_dir" => tmpdir,
      "directory_server" => {
        "v1_port" => 12345,
      },
      "domain" => "default",
      "runtimes" => ["ruby", "java"],
    }
  end

  subject(:bootstrap) do
    Dea::Bootstrap.new(@config)
  end

  describe "logging setup" do
    after do
      bootstrap.setup_logging
    end

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
    before do
      bootstrap.setup_droplet_registry
    end

    it "should create a new droplet registry" do
      bootstrap.droplet_registry.should be_a(Dea::DropletRegistry)
      bootstrap.droplet_registry.base_dir.should == File.join(@config["base_dir"], "droplets")
    end
  end

  describe "instance registry setup" do
    before do
      bootstrap.setup_instance_registry
    end

    it "should create a new instance registry" do
      bootstrap.instance_registry.should be_a(Dea::InstanceRegistry)
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
    it "should stop and flush nats" do
      bootstrap.setup_signal_handlers
      bootstrap.setup_instance_registry
      bootstrap.setup_router_client
      bootstrap.setup_directory_server_v2

      nats_client_mock = mock("nats_client")
      nats_client_mock.should_receive(:flush)

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

      bootstrap.stub(:nats).and_return(nats_mock)

      # Don't want to exit tests :)
      bootstrap.stub(:terminate)

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

  describe "#runtime" do
    before do
      bootstrap.setup_runtimes
    end

    it "returns nil when a runtime is not mentioned in the configuration" do
      bootstrap.runtime("php").should be_nil
    end

    it "returns nil when a runtime is not valid" do
      runtime = mock("Dea::Runtime")
      runtime.should_receive(:validate).once.and_raise(Dea::Runtime::BaseError.new("Error"))

      Dea::Runtime.stub(:new).and_return(runtime)

      bootstrap.runtime("ruby").should be_nil
    end

    it "returns a Runtime object when a runtime is valid" do
      runtime = mock("Dea::Runtime")
      runtime.should_receive(:validate).once.and_return

      Dea::Runtime.stub(:new).and_return(runtime)

      bootstrap.runtime("ruby").should == runtime
    end

    it "caches valid runtimes" do
      runtime = mock("Dea::Runtime")
      runtime.should_receive(:validate).once.and_return

      Dea::Runtime.stub(:new).and_return(runtime)

      r1 = bootstrap.runtime("ruby")
      r2 = bootstrap.runtime("ruby")
      r1.should == r2
    end
  end
end
