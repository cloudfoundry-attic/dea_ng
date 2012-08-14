# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"
require "dea/instance"

describe Dea::Bootstrap do
  include_context "tmpdir"

  before do
    @config = {
      "base_dir" => tmpdir
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

      nats_client_mock = mock("nats_client")
      nats_client_mock.should_receive(:flush)

      nats_mock = mock("nats")
      nats_mock.should_receive(:stop)
      nats_mock.should_receive(:client).and_return(nats_client_mock)
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

  describe "crash reaping" do
    before :each do
      bootstrap.setup_instance_registry

      @time_of_check = 20
      x = Time.now
      x.stub(:to_i).and_return(@time_of_check)
      Time.stub(:now).and_return(x)

      @crash_lifetime = 10

      bootstrap.stub(:config).and_return({ "crash_lifetime_secs" => @crash_lifetime })
    end

    after :each do
      bootstrap.reap_crashes
    end

    it "should reap crashes that are too old" do
      [15, 5].each_with_index do |age, ii|
        instance = register_crashed_instance(bootstrap.instance_registry, ii, age)
        expect_reap_if(@time_of_check - age > @crash_lifetime, instance,
                       bootstrap.instance_registry)
      end
    end

    it "should reap all but the most recent crash for an app" do
      [15, 14, 13].each_with_index do |age, ii|
        instance = register_crashed_instance(bootstrap.instance_registry, 0, age)
        expect_reap_if(ii != 0, instance, bootstrap.instance_registry)
      end
    end

    def register_crashed_instance(instance_registry, app_id, state_ts)
      instance = Dea::Instance.new(bootstrap, "application_id" => app_id)
      instance.state = Dea::Instance::State::CRASHED
      instance.stub(:state_timestamp).and_return(state_ts)
      instance_registry.register(instance)
      instance
    end

    def expect_reap_if(pred, instance, instance_registry)
      method = pred ? :should_receive : :should_not_receive

      instance.send(method, :destroy_crash_artifacts)
      instance_registry.send(method, :unregister).with(instance)
    end
  end
end
