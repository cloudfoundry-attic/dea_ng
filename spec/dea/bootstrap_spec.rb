# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

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

  describe "heartbeats" do
    it "should periodically send out heartbeats for all registered instances" do
      nats_mock = NatsClientMock.new({})
      Dea::Nats.stub(:new).and_return(nats_mock)

      bootstrap = Dea::Bootstrap.new("intervals" => { "heartbeat" => 0.01 })
      bootstrap.setup_instance_registry
      bootstrap.setup_nats

      # Register initial instances
      instances = []
      5.times do |ii|
        instance = Dea::Instance.new(bootstrap,
                                     "application_id" => ii,
                                     "application_version" => ii,
                                     "instance_index" => ii)
        bootstrap.instance_registry.register(instance)
        instances << instance
      end

      # Unregister an instance with each heartbeat received
      hbs = []
      nats_mock.subscribe("dea.heartbeat") do |msg, _|
        hbs << Yajl::Parser.parse(msg)
        if hbs.size == 5
          EM.stop
        else
          bootstrap.instance_registry.unregister(instances[hbs.size - 1])
        end
      end

      em(:timeout => 1) do
        bootstrap.setup_sweepers
      end

      hbs.size.should == instances.size
      instances.size.times do |ii|
        hbs[ii].has_key?("dea").should be_true
        hbs[ii]["droplets"].size.should == (instances.size - ii)

        # Check that we received the correct heartbeats
        hbs[ii]["droplets"].each_with_index do |instance_hb, jj|
          hb_keys = %w[droplet version instance index state state_timestamp]
          instance_hb.keys.should == hb_keys

          instance = instances[ii + jj]
          instance_hb["droplet"].should == instance.application_id
          instance_hb["version"].should == instance.application_version
          instance_hb["instance"].should == instance.instance_id
          instance_hb["index"].should == instance.instance_index
          instance_hb["state"].should == instance.state
        end
      end
    end
  end

  describe "on router start" do
    before :each do
      @nats_mock = NatsClientMock.new({})
      NATS.stub(:connect).and_return(@nats_mock)

      bootstrap = Dea::Bootstrap.new({})
      bootstrap.setup_instance_registry
      bootstrap.setup_nats
      bootstrap.nats.start

      @instances = []

      states = [Dea::Instance::State::RUNNING,
                Dea::Instance::State::STOPPED,
                Dea::Instance::State::RUNNING]
      all_uris = [["foo"], ["bar"], []]

      states.zip(all_uris).each_with_index do |xs, ii|
        state, uris = xs
        instance = Dea::Instance.new(bootstrap,
                                     "application_id"   => ii,
                                     "application_uris" => uris)
        instance.state = state
        @instances << instance
        bootstrap.instance_registry.register(instance)
      end
    end

    it "should only register running instances with uris" do
      responses = []
      @nats_mock.subscribe("router.register") do |msg, _|
        responses << Yajl::Parser.parse(msg)
      end

      @nats_mock.publish("router.start")

      expected = {
        "dea"  => bootstrap.uuid,
        "app"  => @instances[0].application_id,
        "uris" => @instances[0].application_uris,
      }

      responses.size.should == 1
      responses[0].should == expected
    end
  end

  describe "find droplet" do
    before :each do
      @nats_mock = NatsClientMock.new({})
      NATS.stub(:connect).and_return(@nats_mock)

      bootstrap = Dea::Bootstrap.new({})
      bootstrap.setup_instance_registry
      bootstrap.setup_nats
      bootstrap.nats.start

      @instances = []

      [Dea::Instance::State::RUNNING,
       Dea::Instance::State::STOPPED,
       Dea::Instance::State::STARTING].each_with_index do |state, ii|
        instance = Dea::Instance.new(bootstrap,
                                     "application_id"      => (ii == 0) ? 0 : 1,
                                     "application_version" => ii,
                                     "instance_index"      => ii,
                                     "application_uris"    => ["foo", "bar"])
        instance.state = state
        @instances << instance
        bootstrap.instance_registry.register(instance)
      end
    end

    it "should respond with a correctly formatted message" do
      responses = find_droplet(@nats_mock,
                               { "droplet" => @instances[0].application_id })
      expected = {
        "dea"      => bootstrap.uuid,
        "droplet"  => @instances[0].application_id,
        "version"  => @instances[0].application_version,
        "instance" => @instances[0].instance_id,
        "index"    => @instances[0].instance_index,
        "state"    => @instances[0].state,
        "state_timestamp" => @instances[0].state_timestamp,
      }

      responses.size.should == 1
      responses[0].should == expected
    end

    it "should include 'stats' if requested" do
      responses = find_droplet(@nats_mock,
                               { "droplet" => @instances[0].application_id,
                                 "include_stats" => true})
      expected = {
        "name" => @instances[0].application_name,
        "uris" => @instances[0].application_uris,
      }

      responses.size.should == 1
      responses[0]["stats"].should == expected
    end

    it "should support filtering by application version" do
      responses = find_droplet(@nats_mock,
                               { "droplet" => @instances[1].application_id,
                                 "version" => @instances[1].application_version})

      responses.size.should == 1
      responses[0]["instance"].should == @instances[1].instance_id
    end

    it "should support filtering by instance index" do
      responses = find_droplet(@nats_mock,
                               { "droplet" => @instances[1].application_id,
                                 "indices" => [@instances[2].instance_index]})

      responses.size.should == 1
      responses[0]["instance"].should == @instances[2].instance_id
    end

    it "should support filtering by state" do
      responses = find_droplet(@nats_mock,
                               { "droplet" => @instances[1].application_id,
                                 "states" => [@instances[2].state]})

      responses.size.should == 1
      responses[0]["instance"].should == @instances[2].instance_id
    end

    it "should support filtering with multiple values" do
      filters = %w[indices instances states]
      getters = %w[instance_index instance_id state].map(&:to_sym)

      filters.zip(getters).each do |filter, getter|
        request = {
          "droplet" => @instances[1].application_id,
          filter    => @instances.slice(1, 2).map(&getter)
        }

        responses = find_droplet(@nats_mock, request)

        responses.size.should == 2
        ids = responses.map { |r| r["instance"] }
        ids.include?(@instances[1].instance_id).should be_true
        ids.include?(@instances[2].instance_id).should be_true
      end
    end

    def find_droplet(nats_mock, request)
      responses = []
      nats_mock.subscribe("results") do |msg, _|
        responses << Yajl::Parser.parse(msg)
      end

      nats_mock.publish("dea.find.droplet", request, "results")

      responses
    end
  end
end
