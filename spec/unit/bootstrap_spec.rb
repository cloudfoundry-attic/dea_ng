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
    allow(nats_client_mock).to receive(:flush) { |&blk| blk.call }
    nats_client_mock
  end

  describe "logging setup" do
    after { bootstrap.setup_logging }

    it "should use a file sink when specified" do
      @config = { "logging" => { "file" => File.join(tmpdir, "out.log") } }

      allow(Steno).to receive(:init) do |config|
        expect(
          config.sinks.any? do |sink|
            sink.kind_of?(Steno::Sink::IO)
          end
        ).to be true
      end
    end

    it "should use a syslog sink when specified" do
      @config = { "logging" => { "syslog" => "ident" } }

      allow(Steno).to receive(:init) do |config|
        expect(
          config.sinks.any? do |sink|
            sink.kind_of?(Steno::Sink::Syslog)
          end
        ).to be true
      end
    end

    it "should set the default log level when specified" do
      @config = { "logging" => { "level" => "debug" } }

      allow(Steno).to receive(:init) do |config|
        expect(config.default_log_level).to eq(:debug)
      end
    end

    it "logs the creation of the DEA" do
      @config = { "logging" => { "level" => "debug" } }

      logger = double("logger")
      allow(bootstrap).to receive(:logger).and_return(logger)
      allow(logger).to receive(:info).with("Dea started")
    end
  end

  describe "loggregator setup" do

    it "should configure when router is valid" do
      @config = { "index" => 0, "loggregator" => { "router" => "localhost:5432" } }

      allow(LoggregatorEmitter::Emitter).to receive(:new).with("localhost:5432", "DEA", "DEA", 0)
      allow(LoggregatorEmitter::Emitter).to receive(:new).with("localhost:5432", "DEA", "STG", 0)
      bootstrap.setup_loggregator
    end

    it "should validate host" do
      @config = { "index" => 0, "loggregator" => { "router" => ":5432" } }

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
      expect(bootstrap.warden_container_lister).to be_a(Container)
    end
  end

  describe "droplet registry setup" do
    before { bootstrap.setup_droplet_registry }

    it "should create a new droplet registry" do
      expect(bootstrap.droplet_registry).to be_a(Dea::DropletRegistry)
      expect(bootstrap.droplet_registry.base_dir).to eq(File.join(@config["base_dir"], "droplets"))
    end
  end

  describe "instance registry setup" do
    before { bootstrap.setup_instance_registry }

    it "should create a new instance registry" do
      expect(bootstrap.instance_registry).to be_a(Dea::InstanceRegistry)
    end
  end

  describe "staging task registry setup" do
    it "creates staging task registry" do
      expect {
        bootstrap.setup_staging_task_registry
      }.to change { bootstrap.staging_task_registry }.from(nil)

      bootstrap.staging_task_registry.tap do |r|
        expect(r).to be_a(Dea::StagingTaskRegistry)
      end
    end
  end

  describe "directory setup" do
    before do
      bootstrap.setup_directories
    end

    %W(db droplets instances tmp).each do |dir|
      it "should create '#{dir}'" do
        expect(File.directory?(File.join(tmpdir, dir))).to be true
      end
    end
  end

  describe "pid file setup" do
    it "should create a pid file" do
      pid_filename = File.join(tmpdir, "pid")
      bootstrap = Dea::Bootstrap.new("pid_filename" => pid_filename)
      bootstrap.setup_pid_file

      pid = File.read(pid_filename).chomp.to_i
      expect(pid).to eq(Process.pid)
    end

    it "should raise when it can't create the pid file" do
      expect do
        pid_filename = File.join(tmpdir, "doesnt_exist", "pid")
        bootstrap = Dea::Bootstrap.new("pid_filename" => pid_filename)
        bootstrap.setup_pid_file
      end.to raise_error Errno::ENOENT
    end
  end

  describe "#reap_unreferenced_droplets" do
    let(:droplet_registry) do
      droplet_registry = {}
      ["a", "b", "c", "d", "e", "f"].each do |sha|
        droplet_registry[sha] = double("droplet_#{sha}")
        allow(droplet_registry[sha]).to receive(:destroy)
      end
      droplet_registry
    end

    let(:instance_registry) do
      instance_registry = []
      ["a", "b"].each do |sha|
        instance_registry << double("instance_#{sha}")
        allow(instance_registry.last).to receive(:droplet_sha1).and_return(sha)
      end
      instance_registry
    end

    let(:staging_task_registry) do
      staging_task_registry= []
      ["e", "f"].each do |sha|
        staging_task_registry << double("staging_task_#{sha}")
        allow(staging_task_registry.last).to receive(:droplet_sha1).and_return(sha)
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
      allow(bootstrap).to receive(:instance_registry).and_return(instance_registry)
      allow(bootstrap).to receive(:staging_task_registry).and_return(staging_task_registry)
      allow(bootstrap).to receive(:droplet_registry).and_return(droplet_registry)
    end

    it "should delete any unreferenced droplets from the registry" do
      bootstrap.reap_unreferenced_droplets
      expect(bootstrap.droplet_registry.keys).to eq(referenced_shas)
    end

    it "should destroy any unreferenced droplets" do
      unreferenced_shas.each do |sha|
        allow(droplet_registry[sha]).to receive(:destroy)
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
        allow(instance_registry.last).to receive(:warden_handle).and_return(warden_handle)
      end
      instance_registry
    end

    let(:staging_task_registry) do
      staging_task_registry= []
      ["c"].each do |warden_handle|
        staging_task_registry << double("staging_task_#{warden_handle}")
        allow(staging_task_registry.last).to receive(:warden_handle).and_return(warden_handle)
      end
      staging_task_registry
    end

    before do
      bootstrap.setup_warden_container_lister
      bootstrap.setup_warden_container_lister
      allow(bootstrap.warden_container_lister).to receive(:list).and_return list_response
      allow(bootstrap).to receive(:instance_registry).and_return(instance_registry)
      allow(bootstrap).to receive(:staging_task_registry).and_return(staging_task_registry)
    end

    it "should not reap orphaned containers on the first time" do
      with_event_machine do
        expect(warden_containers).to_not receive(:handle=).with('a')
        expect(warden_containers).to_not receive(:handle=).with('b')
        expect(warden_containers).to_not receive(:handle=).with('c')
        expect(warden_containers).to_not receive(:handle=).with('d')
        expect(warden_containers).to_not receive(:destroy!)
        bootstrap.reap_orphaned_containers

        after_defers_finish do
          done
        end
      end
    end

    it "should reap orphaned containers if they remain orphan for two ticks" do
      with_event_machine do
        expect(warden_containers).to_not receive(:handle=).with('a')
        expect(warden_containers).to_not receive(:handle=).with('c')
        expect(warden_containers).to_not receive(:handle=).with('d')
        allow(warden_containers).to receive(:handle=).with('b')
        allow(warden_containers).to receive(:destroy!)
        bootstrap.reap_orphaned_containers
        instance_registry << double("instance_d")
        allow(instance_registry.last).to receive(:warden_handle).and_return("d")
        bootstrap.reap_orphaned_containers

        after_defers_finish do
          done
        end
      end
    end

    it "is resistant to errors" do
      allow(warden_containers).to receive(:list).and_raise("error happened")
      logger = double("logger")
      allow(bootstrap).to receive(:logger).at_least(:once).and_return(logger)
      allow(logger).to receive(:debug)
      allow(logger).to receive(:error).with("error happened")

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

      allow(bootstrap).to receive(:nats).and_return(nats_client_mock)

      # stubbing this to avoid a runtime exception
      allow(EM).to receive(:add_periodic_timer)

      bootstrap.setup_varz

      expect(VCAP::Component.varz[:stacks]).to eq(["Linux"])
    end
  end

  describe "#periodic_varz_update" do
    before do
      bootstrap.setup_resource_manager
      bootstrap.setup_warden_container_lister
      bootstrap.setup_instance_registry
      allow(bootstrap.config).to receive(:minimum_staging_memory_mb).and_return(333)
      allow(bootstrap.config).to receive(:minimum_staging_disk_mb).and_return(444)
      allow(bootstrap.resource_manager).to receive(:number_reservable).and_return(0)
      allow(bootstrap.resource_manager).to receive(:available_disk_ratio).and_return(0)
      allow(bootstrap.resource_manager).to receive(:available_memory_ratio).and_return(0)
      allow(bootstrap.warden_container_lister).to receive(:list).and_return list_response
    end

    let(:list_response) do
      Warden::Protocol::ListResponse.new(
        :handles => []
      )
    end

    describe "can_stage" do
      it "is 0 when there is not enough free memory or disk space" do
        allow(bootstrap.resource_manager).to receive(:number_reservable).and_return(0)
        bootstrap.periodic_varz_update

        expect(VCAP::Component.varz[:can_stage]).to eq(0)
      end

      it "is 1 when there is enough memory and disk space" do
        allow(bootstrap.resource_manager).to receive(:number_reservable).and_return(3)
        bootstrap.periodic_varz_update

        expect(VCAP::Component.varz[:can_stage]).to eq(1)
      end
    end

    describe "reservable_stagers" do
      it "uses the value from resource_manager#number_reservable" do
        allow(bootstrap.resource_manager).to receive(:number_reservable).with(333, 444).and_return(456)
        bootstrap.periodic_varz_update

        expect(VCAP::Component.varz[:reservable_stagers]).to eq(456)
      end
    end

    describe "available_memory_ratio" do
      it "uses the value from resource_manager#available_memory_ratio" do
        allow(bootstrap.resource_manager).to receive(:available_memory_ratio).and_return(0.5)
        bootstrap.periodic_varz_update

        expect(VCAP::Component.varz[:available_memory_ratio]).to eq(0.5)
      end
    end

    describe "available_disk_ratio" do
      it "uses the value from resource_manager#available_memory_ratio" do
        allow(bootstrap.resource_manager).to receive(:available_disk_ratio).and_return(0.75)
        bootstrap.periodic_varz_update

        expect(VCAP::Component.varz[:available_disk_ratio]).to eq(0.75)
      end
    end

    describe "warden_containers" do
      context "when there are no containers" do
        it "is an empty array" do
          bootstrap.periodic_varz_update
          expect(VCAP::Component.varz[:warden_containers]).to eq([])
        end
      end

      context "with an active container" do
        let(:list_response) do
          Warden::Protocol::ListResponse.new(
            :handles => ["ahandle", "anotherhandle"])
        end

        it "is a hash with keys matching the container guid" do
          bootstrap.periodic_varz_update
          expect(VCAP::Component.varz[:warden_containers]).to eq(["ahandle", "anotherhandle"])
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

          expect(VCAP::Component.varz[:instance_registry]).to eq({})
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

          expect(varz.keys).to eq(["app-1"])
          expect(varz["app-1"][instance_1.instance_id]).to include(
            "state" => "BORN",
            "state_timestamp" => Time.now.to_f
          )
        end

        it "uses the values from stat_collector" do
          allow(instance_1.stat_collector).to receive(:used_memory_in_bytes).and_return(999)
          allow(instance_1.stat_collector).to receive(:used_disk_in_bytes).and_return(40)
          allow(instance_1.stat_collector).to receive(:computed_pcpu).and_return(0.123)

          bootstrap.periodic_varz_update

          varz = VCAP::Component.varz[:instance_registry]

          expect(varz.keys).to eq(["app-1"])
          expect(varz["app-1"][instance_1.instance_id]).to include(
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

          expect(varz.keys).to eq(["app-1"])
          expect(varz["app-1"].keys).to include(instance_1.instance_id, instance_2.instance_id)
        end
      end
    end
  end

  describe "#start_nats" do
    before do
      allow(EM).to receive(:add_periodic_timer)
      allow(bootstrap).to receive(:uuid).and_return("unique-dea-id")
      bootstrap.setup_nats
    end

    it "starts nats" do
      allow(bootstrap.nats).to receive(:start)
      bootstrap.start_nats
    end

    it "sets up staging responder to respond to staging requests" do
      bootstrap.setup_staging_task_registry
      bootstrap.setup_directory_server_v2
      bootstrap.start_nats

      responder = bootstrap.responders.detect { |r| r.is_a?(Dea::Responders::Staging) }
      expect(responder).to_not be_nil

      responder.tap do |r|
        expect(r.nats).to be_a(Dea::Nats)
        expect(r.dea_id).to be_a(String)
        expect(r.bootstrap).to eq(bootstrap)
        expect(r.staging_task_registry).to be_a(Dea::StagingTaskRegistry)
        expect(r.dir_server).to be_a(Dea::DirectoryServerV2)
        expect(r.config).to be_a(Dea::Config)
      end
    end
  end

  describe "#start_finish" do
    before do
      allow(EM).to receive(:add_periodic_timer).and_return(nil)
      allow(EM).to receive(:add_timer).and_return(nil)
      allow(bootstrap).to receive(:uuid).and_return("unique-dea-id")
      bootstrap.setup_nats
      bootstrap.setup_instance_registry
      bootstrap.setup_staging_task_registry
      bootstrap.setup_resource_manager
      bootstrap.start_nats
    end

    it "advertises dea" do
      allow_any_instance_of(Dea::Responders::DeaLocator).to receive(:advertise)
      bootstrap.start_finish
    end

    it "advertises staging" do
      allow_any_instance_of(Dea::Responders::StagingLocator).to receive(:advertise)
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
        allow(bootstrap).to receive(:send_heartbeat)
        bootstrap.start_finish
      end
    end
  end

  describe "counting logs" do
    it "registers a log counter with the component" do
      log_counter = Steno::Sink::Counter.new
      allow(Steno::Sink::Counter).to receive(:new).once.and_return(log_counter)

      allow(VCAP::Component).to receive(:uuid)
      allow(bootstrap).to receive(:nats).and_return(nats_client_mock)

      allow(Steno).to receive(:init) do |steno_config|
        expect(steno_config.sinks).to include log_counter
      end

      allow(VCAP::Component).to receive(:register).with(hash_including(:log_counter => log_counter))
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
      allow(bootstrap.instance_manager).to receive(:create_instance).with(instance_data).and_return(instance)
      allow(instance).to receive(:start)
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
      allow(bootstrap).to receive(:download_buildpacks)
      allow(bootstrap).to receive(:snapshot) { double(:snapshot, :load => nil) }
      allow(bootstrap).to receive(:start_component)
      allow(bootstrap).to receive(:setup_sweepers)
      allow(bootstrap).to receive(:start_nats)
      allow(bootstrap).to receive(:start_directory_server)
      allow(bootstrap).to receive(:register_directory_server_v2)
      allow(bootstrap).to receive(:directory_server_v2) { double(:directory_server_v2, :start => nil) }
      allow(bootstrap).to receive(:setup_register_routes)
      allow(bootstrap).to receive(:setup_varz)
      allow(bootstrap).to receive(:start_finish)
    end

    describe "snapshot" do
      before do
        allow(bootstrap).to receive(:snapshot).and_call_original
      end

      it "loads the snapshot on startup" do
        allow_any_instance_of(Dea::Snapshot).to receive(:load)

        bootstrap.setup_snapshot
        bootstrap.start
      end
    end
  end

  describe "send_heartbeat" do
    before do
      allow(EM).to receive(:add_periodic_timer).and_return(nil)
      allow(EM).to receive(:add_timer).and_return(nil)
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

  describe 'download_buildpacks' do
    let(:buildpack_uri) { URI::join(@config['cc_url'], '/internal/buildpacks').to_s }

    before do
      @config['staging'] = { 'enabled' => true }
      @config['cc_url'] = 'https://user:password@api.localhost.xip.io'
    end

    context 'when staging is disabled' do
      before { @config.delete('staging') }

      it 'does not download' do
        expect(EM::HttpRequest).to_not receive(:new)
        with_event_machine { bootstrap.download_buildpacks }
      end
    end

    context 'when get returns with a non-200' do
      it 'does not create an AdminBuildpacksDownloader' do
        expect(AdminBuildpackDownloader).not_to receive(:new)

        stub_request(:get, buildpack_uri).to_return(status: 500)
        with_event_machine { bootstrap.download_buildpacks }
      end
    end

    context 'when it retrieves the buildpacks' do
      it 'downloads the buildpacks' do
        stub_request(:get, buildpack_uri).to_return(status: 200, body: '[{ "key": "first-buildpack", "url": "first-url"}, {"key": "second-buildpack", "url": "second-url"}]')

        expect(AdminBuildpackDownloader).to receive(:new).with(
          [{key: 'first-buildpack', url: URI('first-url')},{key:'second-buildpack',url: URI('second-url')}],
          File.join(@config['base_dir'], "admin_buildpacks"))

        with_event_machine { bootstrap.download_buildpacks }
      end
    end
  end
end
