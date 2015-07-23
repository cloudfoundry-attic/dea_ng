# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"
require "dea/starting/instance"
require "steno/sink/counter"

describe Dea::Bootstrap do
  stub_nats
  include_context "tmpdir"

  before do
    @config = {
      "base_dir" => tmpdir,
      "directory_server" => {},
      "domain" => "default",
      "logging" => {}
    }
  end

  subject(:bootstrap) do
    bootstrap = nil
    if EM.reactor_running?
      with_event_machine do
        bootstrap = Dea::Bootstrap.new(@config)
        done
      end
    else
      bootstrap = Dea::Bootstrap.new(@config)
    end
    bootstrap
  end

  let(:nats_client_mock) do
    nats_client_mock = double("nats_client").as_null_object
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

    it "logs the creation of the DEA" do
      @config = { "logging" => { "level" => "debug" } }

      logger = double("logger")
      bootstrap.should_receive(:logger).and_return(logger)
      logger.should_receive(:info).with("Dea started")
    end
  end

  describe "loggregator setup" do

    it "should configure when router is valid" do
      @config = { "index" => 0, "loggregator" => { "router" => "localhost:5432", "shared_secret" => "secret" } }

      LoggregatorEmitter::Emitter.should_receive(:new).with("localhost:5432", "DEA", 0, "secret")
      LoggregatorEmitter::Emitter.should_receive(:new).with("localhost:5432", "STG", 0, "secret")
      bootstrap.setup_loggregator
    end

    it "should validate host" do
      @config = { "index" => 0, "loggregator" => { "router" => ":5432", "shared_secret" => "secret" } }

      expect {
        bootstrap.setup_loggregator
      }.to raise_exception(ArgumentError)
    end

  end

  describe "container lister setup" do
    before do
      @config["warden_socket"] = "123"
    end

    it "should create a new warden container to be used to send .list requests for varz updates" do
      expect(WardenClientProvider).to receive(:new).with("123")
      bootstrap.setup_warden_container_lister
      bootstrap.warden_container_lister.should be_a(Container)
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

  describe "#reap_unreferenced_droplets" do
    let(:droplet_registry) do
      droplet_registry = {}
      ["a", "b", "c", "d", "e", "f"].each do |sha|
        droplet_registry[sha] = double("droplet_#{sha}")
        droplet_registry[sha].stub(:destroy)
      end
      droplet_registry
    end

    let(:instance_registry) do
      instance_registry = []
      ["a", "b"].each do |sha|
        instance_registry << double("instance_#{sha}")
        instance_registry.last.stub(:droplet_sha1).and_return(sha)
      end
      instance_registry
    end

    let(:staging_task_registry) do
      staging_task_registry= []
      ["e", "f"].each do |sha|
        staging_task_registry << double("staging_task_#{sha}")
        staging_task_registry.last.stub(:droplet_sha1).and_return(sha)
      end
      staging_task_registry
    end

    let(:unreferenced_shas) do
      droplet_registry.keys - instance_registry.map(&:droplet_sha1) - staging_task_registry.map(&:droplet_sha1)
    end

    let(:referenced_shas) do
      instance_registry.map(&:droplet_sha1) + staging_task_registry.map(&:droplet_sha1)
    end

    before do
      bootstrap.stub(:instance_registry).and_return(instance_registry)
      bootstrap.stub(:staging_task_registry).and_return(staging_task_registry)
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

  describe "reap orphaned_containers" do
    let(:warden_containers) { bootstrap.warden_container_lister }
    let(:list_response) do
      Warden::Protocol::ListResponse.new(
        :handles => ["a", "b", "c", "d"]
      )
    end

    let(:instance_registry) do
      instance_registry = []
      ["a"].each do |warden_handle|
        instance_registry << double("instance_#{warden_handle}")
        instance_registry.last.stub(:warden_handle).and_return(warden_handle)
      end
      instance_registry
    end

    let(:staging_task_registry) do
      staging_task_registry= []
      ["c"].each do |warden_handle|
        staging_task_registry << double("staging_task_#{warden_handle}")
        staging_task_registry.last.stub(:warden_handle).and_return(warden_handle)
      end
      staging_task_registry
    end

    before do
      bootstrap.setup_warden_container_lister
      bootstrap.setup_warden_container_lister
      allow(bootstrap.warden_container_lister).to receive(:list).and_return list_response
      bootstrap.stub(:instance_registry).and_return(instance_registry)
      bootstrap.stub(:staging_task_registry).and_return(staging_task_registry)
    end

    it "should not reap orphaned containers on the first time" do
      with_event_machine do
        warden_containers.should_not_receive(:handle=).with('a')
        warden_containers.should_not_receive(:handle=).with('b')
        warden_containers.should_not_receive(:handle=).with('c')
        warden_containers.should_not_receive(:handle=).with('d')
        warden_containers.should_not_receive(:destroy!)
        bootstrap.reap_orphaned_containers

        after_defers_finish do
          done
        end
      end
    end

    it "should reap orphaned containers if they remain orphan for two ticks" do
      with_event_machine do
        warden_containers.should_not_receive(:handle=).with('a')
        warden_containers.should_not_receive(:handle=).with('c')
        warden_containers.should_not_receive(:handle=).with('d')
        warden_containers.should_receive(:handle=).with('b')
        warden_containers.should_receive(:destroy!)
        bootstrap.reap_orphaned_containers
        instance_registry << double("instance_d")
        instance_registry.last.stub(:warden_handle).and_return("d")
        bootstrap.reap_orphaned_containers

        after_defers_finish do
          done
        end
      end
    end

    it "is resistant to errors" do
      warden_containers.stub(:list).and_raise("error happened")
      logger = double("logger")
      bootstrap.should_receive(:logger).at_least(:once).and_return(logger)
      allow(logger).to receive(:debug)
      logger.should_receive(:error).with("error happened")

      with_event_machine do
        bootstrap.reap_orphaned_containers

        after_defers_finish do
          done
        end
      end
    end
  end

  describe "start_component" do
    it "adds stacks to varz" do
      @config["stacks"] = [{ "name" => "Linux" }]

      bootstrap.stub(:nats).and_return(nats_client_mock)

      # stubbing this to avoid a runtime exception
      EM.stub(:add_periodic_timer)

      bootstrap.setup_varz

      VCAP::Component.varz[:stacks].should == ["Linux"]
    end
  end

  describe "#periodic_varz_update" do
    before do
      bootstrap.setup_resource_manager
      bootstrap.setup_warden_container_lister
      bootstrap.setup_instance_registry
      bootstrap.config.stub(:minimum_staging_memory_mb => 333)
      bootstrap.config.stub(:minimum_staging_disk_mb => 444)
      bootstrap.resource_manager.stub(number_reservable: 0,
        available_disk_ratio: 0,
        available_memory_ratio: 0)
      allow(bootstrap.warden_container_lister).to receive(:list).and_return list_response
    end

    let(:list_response) do
      Warden::Protocol::ListResponse.new(
        :handles => []
      )
    end

    describe "can_stage" do
      it "is 0 when there is not enough free memory or disk space" do
        bootstrap.resource_manager.stub(:number_reservable).and_return(0)
        bootstrap.periodic_varz_update

        VCAP::Component.varz[:can_stage].should == 0
      end

      it "is 1 when there is enough memory and disk space" do
        bootstrap.resource_manager.stub(:number_reservable).and_return(3)
        bootstrap.periodic_varz_update

        VCAP::Component.varz[:can_stage].should == 1
      end
    end

    describe "reservable_stagers" do
      it "uses the value from resource_manager#number_reservable" do
        bootstrap.resource_manager.stub(:number_reservable).with(333, 444).and_return(456)
        bootstrap.periodic_varz_update

        VCAP::Component.varz[:reservable_stagers].should == 456
      end
    end

    describe "available_memory_ratio" do
      it "uses the value from resource_manager#available_memory_ratio" do
        bootstrap.resource_manager.stub(:available_memory_ratio).and_return(0.5)
        bootstrap.periodic_varz_update

        VCAP::Component.varz[:available_memory_ratio].should == 0.5
      end
    end

    describe "available_disk_ratio" do
      it "uses the value from resource_manager#available_memory_ratio" do
        bootstrap.resource_manager.stub(:available_disk_ratio).and_return(0.75)
        bootstrap.periodic_varz_update

        VCAP::Component.varz[:available_disk_ratio].should == 0.75
      end
    end

    describe "warden_containers" do
      context "when there are no containers" do
        it "is an empty array" do
          bootstrap.periodic_varz_update
          VCAP::Component.varz[:warden_containers].should == []
        end
      end

      context "with an active container" do
        let(:list_response) do
          Warden::Protocol::ListResponse.new(
            :handles => ["ahandle", "anotherhandle"])
        end

        it "is a hash with keys matching the container guid" do
          bootstrap.periodic_varz_update
          VCAP::Component.varz[:warden_containers].should == ["ahandle", "anotherhandle"]
        end
      end

      context 'when the warden client is disconnected' do
        before do
          allow(bootstrap.warden_container_lister).to receive(:list).and_raise(::EM::Warden::Client::ConnectionError.new)
        end

        it 'should not explode' do
          expect {
            bootstrap.periodic_varz_update
          }.not_to raise_error
        end
      end
    end

    describe "instance_registry" do
      let(:instance_1) do
        Dea::Instance.new(bootstrap, "application_id" => "app-1")
      end

      let(:instance_2) do
        Dea::Instance.new(bootstrap, "application_id" => "app-1")
      end

      context "when an empty registry" do
        it "is an empty hash" do
          bootstrap.periodic_varz_update

          VCAP::Component.varz[:instance_registry].should == {}
        end
      end

      context "with a registry with an instance of an app" do
        around { |example| Timecop.freeze(&example) }

        before do
          bootstrap.instance_registry.register(instance_1)
        end

        it "inlines the instance registry grouped by app ID" do
          bootstrap.periodic_varz_update

          varz = VCAP::Component.varz[:instance_registry]

          varz.keys.should == ["app-1"]
          varz["app-1"][instance_1.instance_id].should include(
            "state" => "BORN",
            "state_timestamp" => Time.now.to_f
          )
        end

        it "uses the values from stat_collector" do
          instance_1.stat_collector.stub(:used_memory_in_bytes).and_return(999)
          instance_1.stat_collector.stub(:used_disk_in_bytes).and_return(40)
          instance_1.stat_collector.stub(:computed_pcpu).and_return(0.123)

          bootstrap.periodic_varz_update

          varz = VCAP::Component.varz[:instance_registry]

          varz.keys.should == ["app-1"]
          varz["app-1"][instance_1.instance_id].should include(
            "used_memory_in_bytes" => 999,
            "used_disk_in_bytes" => 40,
            "computed_pcpu" => 0.123
          )
        end
      end

      context "with a registry containing two instances of one app" do
        before do
          bootstrap.instance_registry.register(instance_1)
          bootstrap.instance_registry.register(instance_2)
        end

        it "inlines the instance registry grouped by app ID" do
          bootstrap.periodic_varz_update

          varz = VCAP::Component.varz[:instance_registry]

          varz.keys.should == ["app-1"]
          varz["app-1"].keys.should =~ [
            instance_1.instance_id,
            instance_2.instance_id
          ]
        end
      end
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

    context "when recovering from snapshots" do
      let(:instances) do
        [Dea::Instance.new(bootstrap, valid_instance_attributes),
          Dea::Instance.new(bootstrap, valid_instance_attributes),
        ]
      end

      before do
        instances.each do |instance|
          bootstrap.instance_registry.register(instance)
        end
      end

      it "heartbeats its registry" do
        bootstrap.should_receive(:send_heartbeat)
        bootstrap.start_finish
      end
    end
  end

  describe "counting logs" do
    it "registers a log counter with the component" do
      log_counter = Steno::Sink::Counter.new
      Steno::Sink::Counter.should_receive(:new).once.and_return(log_counter)

      VCAP::Component.stub(:uuid)
      bootstrap.stub(:nats).and_return(nats_client_mock)

      Steno.should_receive(:init) do |steno_config|
        expect(steno_config.sinks).to include log_counter
      end

      VCAP::Component.should_receive(:register).with(hash_including(:log_counter => log_counter))
      subject.setup_logging
      subject.start_component
    end
  end

  describe "handle_dea_directed_start" do
    let(:instance_data) do
      {
        "index" => 0,
        "droplet" => "some-droplet"
      }
    end

    let(:instance) { double("instance", :start => nil) }

    before do
      bootstrap.setup_instance_manager
    end

    it "creates an instance" do
      bootstrap.instance_manager.should_receive(:create_instance).with(instance_data).and_return(instance)
      instance.should_receive(:start)
      bootstrap.handle_dea_directed_start(Dea::Nats::Message.new(nil, nil, instance_data, nil))
    end
  end

  describe "handle_dea_update" do
    let(:app_version) { "version" }
    let(:new_version) { "new version" }

    let(:instance_data) do
      {
        "droplet" => "some-droplet",
        "uris" => ["not used"],
        "version" => new_version
      }
    end

    let(:instance) { double("instance", :start => nil, :running? => true, :application_version => app_version) }
    let(:instance2) { double("instance2", :start => nil, :running? => true, :application_version => app_version) }
    let(:instance_registry) { double("instance_registry") }
    let(:snapshot) { double("snapshot") }

    before do
      bootstrap.setup_instance_manager
    end

    context "with an existing instance" do
      context "when the uris change" do
        let (:new_version) { app_version }

        it "updates the uris, heartbeats and snapshot" do
          expect(bootstrap).to receive(:instance_registry).at_least(:once).and_return(instance_registry)
          expect(bootstrap).to receive(:snapshot).and_return(snapshot)
          instance_updater = double(:instance_updater)
          expect(Dea::InstanceUriUpdater).to receive(:new).with(instance, instance_data["uris"]).ordered.and_return(instance_updater)
          expect(Dea::InstanceUriUpdater).to receive(:new).with(instance2, instance_data["uris"]).ordered.and_return(instance_updater)

          expect(instance_updater).to receive(:update).twice.and_return(true)

          expect(instance).not_to receive(:application_version=).with(new_version)

          expect(instance_registry).to receive(:instances_for_application).and_return({ "myinstanceid" => instance, "mysecondinstanceid" => instance2 })
          expect(instance_registry).not_to receive(:change_instance_id).with(instance)
          expect(instance_registry).not_to receive(:change_instance_id).with(instance2)

          expect(bootstrap).to receive(:send_heartbeat)
          expect(snapshot).to receive(:save)

          bootstrap.handle_dea_update(Dea::Nats::Message.new(nil, nil, instance_data, nil))
        end
      end

      context "when the version changes" do
        it "updates the version, heartbeats and snapshot" do
          expect(bootstrap).to receive(:instance_registry).at_least(:once).and_return(instance_registry)
          expect(bootstrap).to receive(:snapshot).and_return(snapshot)
          instance_updater = double(:instance_updater)
          expect(Dea::InstanceUriUpdater).to receive(:new).with(instance, instance_data["uris"]).and_return(instance_updater)

          expect(instance_updater).to receive(:update).and_return(false)

          expect(instance).to receive(:application_version=).with(new_version)

          expect(instance_registry).to receive(:instances_for_application).and_return({ "myinstanceid" => instance })
          expect(instance_registry).to receive(:change_instance_id).with(instance)

          expect(bootstrap).to receive(:send_heartbeat)
          expect(snapshot).to receive(:save)

          bootstrap.handle_dea_update(Dea::Nats::Message.new(nil, nil, instance_data, nil))
        end
      end
    end

    context "when the instance does not exist" do
      it "does nothing" do
        expect(bootstrap).to receive(:instance_registry).at_least(:once).and_return(instance_registry)
        expect(bootstrap).not_to receive(:snapshot)

        expect(instance_registry).to receive(:instances_for_application).and_return({})

        expect(bootstrap).not_to receive(:send_heartbeat)

        bootstrap.handle_dea_update(Dea::Nats::Message.new(nil, nil, instance_data, nil))
      end
    end
  end

  describe "start" do
    before do
      bootstrap.stub(:snapshot) { double(:snapshot, :load => nil) }
      bootstrap.stub(:start_component)
      bootstrap.stub(:setup_sweepers)
      bootstrap.stub(:start_nats)
      bootstrap.stub(:start_directory_server)
      bootstrap.stub(:register_directory_server_v2)
      bootstrap.stub(:directory_server_v2) { double(:directory_server_v2, :start => nil) }
      bootstrap.stub(:setup_register_routes)
      bootstrap.stub(:setup_varz)
      bootstrap.stub(:start_finish)
    end

    describe "snapshot" do
      before do
        bootstrap.unstub(:snapshot)
      end

      it "loads the snapshot on startup" do
        Dea::Snapshot.any_instance.should_receive(:load)

        bootstrap.setup_snapshot
        bootstrap.start
      end
    end
  end

  describe "send_heartbeat" do
    before do
      EM.stub(:add_periodic_timer => nil, :add_timer => nil)
      bootstrap.setup_nats
      bootstrap.start_nats
    end

    context "when there are no registered instances" do
      it "publishes an empty dea.heartbeat" do
        allow(nats_mock).to receive(:publish)

        bootstrap.send_heartbeat

        expect(nats_mock).to have_received(:publish).with("dea.heartbeat", anything)
      end
    end
  end
end
