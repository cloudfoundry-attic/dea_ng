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
      "logging" => {},
      "hm9000" => {
        "listener_uri" => "https://foobar.com:12345",
        "key_file" => fixture("/certs/hm9000_client.key"),
        "cert_file" => fixture("/certs/hm9000_client.crt"),
        "ca_file" => fixture("/certs/hm9000_ca.crt"),
      }
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

  describe '#setup' do
    it 'sets up the appropriate components' do
      expect(bootstrap).to receive(:validate_config)
      expect(SecureRandom).to receive(:uuid)
      expect(bootstrap).to receive(:setup_logging)
      expect(bootstrap).to receive(:setup_loggregator)
      expect(bootstrap).to receive(:setup_warden_container_lister)
      expect(bootstrap).to receive(:setup_droplet_registry)
      expect(bootstrap).to receive(:setup_instance_registry)
      expect(bootstrap).to receive(:setup_staging_task_registry)
      expect(bootstrap).to receive(:setup_instance_manager)
      expect(bootstrap).to receive(:setup_snapshot)
      expect(bootstrap).to receive(:setup_resource_manager)
      expect(bootstrap).to receive(:setup_router_client)
      expect(bootstrap).to receive(:setup_http_server)
      expect(bootstrap).to receive(:setup_directory_server_v2)
      expect(bootstrap).to receive(:setup_directories)
      expect(bootstrap).to receive(:setup_pid_file)
      expect(bootstrap).to receive(:setup_hm9000)
      expect(bootstrap).to receive(:setup_cloud_controller_client)
      expect(bootstrap).to receive(:setup_nats).ordered
      expect(bootstrap).to receive(:setup_staging_responders).ordered

      bootstrap.setup
    end
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
      @config = { 'logging' => { 'level' => 'debug' } }

      allow(Steno).to receive(:init) do |config|
        expect(config.default_log_level).to eq(:debug)
      end
    end

    it 'sets up a log counter sink' do
      log_counter = Steno::Sink::Counter.new
      allow(Steno::Sink::Counter).to receive(:new).once.and_return(log_counter)

      allow(bootstrap).to receive(:nats).and_return(nats_client_mock)

      allow(Steno).to receive(:init) do |steno_config|
        expect(steno_config.sinks).to include log_counter
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

  describe '#setup_sweepers' do
    let(:instance_registry) { double('instance_registry', :start_reaper => nil) }

    before do
      allow(bootstrap).to receive(:reap_unreferenced_droplets)
      allow(bootstrap).to receive(:reap_orphaned_containers)
      allow(bootstrap).to receive(:instance_registry).and_return(instance_registry)
    end

    it 'reaps unreferenced droplets once' do
      with_event_machine do
        expect(bootstrap).to receive(:reap_unreferenced_droplets).once
        bootstrap.setup_sweepers

        done
      end
    end

    it 'reaps orphaned containers once' do
      with_event_machine do
        expect(bootstrap).to receive(:reap_orphaned_containers).once
        bootstrap.setup_sweepers

        done
      end
    end
  end

  describe '#start_metrics' do
    it 'sets up a periodic timer' do
      expect(bootstrap).to receive(:periodic_metrics_emit)
      expect(EM).to receive(:add_periodic_timer).with(30) { |&block| block.call }

      begin
        with_event_machine do
          bootstrap.start_metrics

          after_defers_finish do
            done
          end
        end
      end
    end
  end

  describe '#periodic_metrics_emit' do
    before do
      @emitter = FakeEmitter.new
      @staging_emitter = FakeEmitter.new
      Dea::Loggregator.emitter = @emitter
      Dea::Loggregator.staging_emitter = @staging_emitter

      bootstrap.setup_instance_registry
      bootstrap.setup_resource_manager

      bootstrap.instance_registry.register(Dea::Instance.new(bootstrap, {}))
      allow(bootstrap.config).to receive(:minimum_staging_memory_mb).and_return(333)
      allow(bootstrap.config).to receive(:minimum_staging_disk_mb).and_return(444)
    end

    it 'emits the correct metrics' do
      expect(bootstrap.resource_manager).to receive(:remaining_memory).and_return(115)
      expect(bootstrap.resource_manager).to receive(:remaining_disk).and_return(666)
      expect(bootstrap.resource_manager).to receive(:available_memory_ratio).and_return(0.22)
      expect(bootstrap.resource_manager).to receive(:available_disk_ratio).and_return(0.86)
      expect(bootstrap.resource_manager).to receive(:cpu_load_average).and_return(0.15)
      expect(bootstrap.resource_manager).to receive(:memory_used_bytes).and_return(1000)
      expect(bootstrap.resource_manager).to receive(:memory_free_bytes).and_return(100)

      expect(bootstrap.instance_registry).to receive(:emit_metrics_state)
      expect(bootstrap.instance_registry).to receive(:emit_container_stats)
      expect(bootstrap.resource_manager).to receive(:number_reservable).with(333, 444).and_return(5)

      bootstrap.periodic_metrics_emit

      expect(@emitter.messages['uptime']).to contain_exactly(include(value: a_kind_of(Integer), unit: 's'))
      expect(@emitter.messages['remaining_memory']).to eq([{value: 115, unit: "mb"}])
      expect(@emitter.messages['remaining_disk']).to eq([{value: 666, unit: "mb"}])
      expect(@emitter.messages['instances']).to eq([{value: 1, unit: 'instances'}])
      expect(@emitter.messages['reservable_stagers']).to eq([{value: 5, unit: 'stagers'}])
      expect(@emitter.messages['available_memory_ratio']).to eq([{value: 0.22, unit: 'P'}])
      expect(@emitter.messages['available_disk_ratio']).to eq([{value: 0.86, unit: 'P'}])
      expect(@emitter.messages['avg_cpu_load']).to eq([{value: 0.15, unit: 'loadavg'}])
      expect(@emitter.messages['mem_used_bytes']).to eq([{value: 1000, unit: 'B'}])
      expect(@emitter.messages['mem_free_bytes']).to eq([{value: 100, unit: 'B'}])
    end
  end

  describe "#start_nats" do
    before do
      allow(EM).to receive(:add_periodic_timer)
      allow(bootstrap).to receive(:uuid).and_return("unique-dea-id")
      bootstrap.setup_nats
    end

    it "starts nats" do
      expect(bootstrap.nats).to receive(:start)
      bootstrap.start_nats
    end
  end

  describe '#start_staging_request_handler' do
    before do
      allow(EM).to receive(:add_periodic_timer)
      allow(bootstrap).to receive(:uuid).and_return("unique-dea-id")
      bootstrap.setup_nats

      bootstrap.setup_staging_task_registry
      bootstrap.setup_directory_server_v2
      bootstrap.setup_staging_responders
      allow(Dea::Responders::Staging).to receive(:new).and_call_original
      allow(Dea::Responders::NatsStaging).to receive(:new).and_call_original
    end

    it "sets up staging responder to respond to nats staging requests" do
      expect(Dea::Responders::NatsStaging).to receive(:new).with(bootstrap.nats, bootstrap.uuid, bootstrap.staging_responder, bootstrap.config)
      bootstrap.start_nats_staging_request_handler

      expect(bootstrap.staging_responder).to_not be_nil

      responder = bootstrap.responders.detect { |r| r.is_a?(Dea::Responders::NatsStaging) }
      expect(responder).to_not be_nil
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
      bootstrap.setup_hm9000
      allow(bootstrap.hm9000).to receive(:send_heartbeat)
      bootstrap.setup_cloud_controller_client
    end

    it "advertises dea" do
      allow_any_instance_of(Dea::Responders::DeaLocator).to receive(:advertise)
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
        expect(bootstrap).to receive(:send_heartbeat)
        bootstrap.start_finish
      end
    end
  end

  describe '#start_app' do
    let(:instance_data) { double('data') }
    let(:instance) { double("instance", :start => nil) }
    let(:evac_handler) { double('evac_handler', evacuating?: false) }
    let(:shutdown_handler) { double('shutdown_handler', shutting_down?: false) }

    before do
      allow(bootstrap).to receive(:evac_handler).and_return(evac_handler)
      allow(bootstrap).to receive(:shutdown_handler).and_return(shutdown_handler)
      bootstrap.setup_signal_handlers
      bootstrap.setup_instance_manager
    end

    it "creates and starts an instance" do
      expect(bootstrap.instance_manager).to receive(:create_instance).with(instance_data).and_return(instance)
      expect(instance).to receive(:start)
      bootstrap.start_app(instance_data)
    end

    context 'when no instance is created' do
      it 'does not start an instance' do
        expect(bootstrap.instance_manager).to receive(:create_instance).with(instance_data).and_return(nil)
        expect(instance).not_to receive(:start)
        bootstrap.start_app(instance_data)
      end
    end

    context 'when evacuating' do
      let(:evac_handler) { double('evac_handler', evacuating?: true) }

      it 'does not create an instance' do
        expect(bootstrap.instance_manager).not_to receive(:create_instance)
        bootstrap.start_app(instance_data)
      end
    end

    context 'when shutting down' do
      let(:shutdown_handler) { double('shutdown_handler', shutting_down?: true) }

      it 'does not create an instance' do
        expect(bootstrap.instance_manager).not_to receive(:create_instance)
        bootstrap.start_app(instance_data)
      end
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
      bootstrap.setup_signal_handlers
      bootstrap.setup_instance_manager
    end

    it "creates an instance" do
      allow(bootstrap.instance_manager).to receive(:create_instance).with(instance_data).and_return(instance)
      allow(instance).to receive(:start)
      bootstrap.start_app(Dea::Nats::Message.new(nil, nil, instance_data, nil).data)
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

  describe '#start' do
    it 'starts up the appropriate DEA subcomponents' do
      expect(bootstrap).to receive(:snapshot) { double(:snapshot, :load => nil) }
      expect(bootstrap).to receive(:download_buildpacks)
      expect(bootstrap).to receive(:setup_sweepers)
      expect(bootstrap).to receive(:directory_server_v2) { double(:directory_server_v2, :start => nil) }
      expect(bootstrap).to receive(:setup_register_routes)
      expect(bootstrap).to receive(:start_finish)
      expect(bootstrap).to receive(:start_metrics)
      expect(bootstrap).to receive(:start_nats).ordered
      expect(bootstrap).to receive(:start_nats_staging_request_handler).ordered
      expect(bootstrap).to receive(:http_server).ordered { double(:http_server, :start => nil) }

      bootstrap.start
    end

    describe "snapshot" do
      before do
        allow(bootstrap).to receive(:snapshot) { double(:snapshot, :load => nil) }
        allow(bootstrap).to receive(:download_buildpacks)
        allow(bootstrap).to receive(:setup_sweepers)
        allow(bootstrap).to receive(:start_nats)
        allow(bootstrap).to receive(:http_server) { double(:http_server, :start => nil) }
        allow(bootstrap).to receive(:directory_server_v2) { double(:directory_server_v2, :start => nil) }
        allow(bootstrap).to receive(:setup_register_routes)
        allow(bootstrap).to receive(:start_finish)
        allow(bootstrap).to receive(:start_metrics)
        allow(bootstrap).to receive(:start_nats_staging_request_handler)
        allow(bootstrap).to receive(:snapshot).and_call_original
      end

      it "loads the snapshot on startup" do
        expect_any_instance_of(Dea::Snapshot).to receive(:load)


        bootstrap.setup_snapshot
        bootstrap.start
      end
    end
  end

  describe '#send_heartbeat' do
    before do
      allow(EM).to receive(:add_periodic_timer).and_return(nil)
      allow(EM).to receive(:add_timer).and_return(nil)
      bootstrap.setup_hm9000
    end

    context "when there are no registered instances" do
      let(:heartbeat) do
        {
          "droplets" => [],
          "dea"      => bootstrap.uuid,
        }
      end
      it "publishes an empty dea.heartbeat" do
        expect(bootstrap.hm9000).to receive(:send_heartbeat).with(heartbeat)

        bootstrap.send_heartbeat
      end
    end
  end

  describe "#setup_hm9000" do
    it 'initializes hm9000' do
      bootstrap.setup_hm9000
      expect(bootstrap.hm9000).to_not be_nil
      expect(bootstrap.hm9000).to be_a_kind_of(HM9000)
    end
  end

  describe '#setup_cloud_controller_client' do
    it 'initializes the cloud_controller client' do
      bootstrap.setup_cloud_controller_client
      expect(bootstrap.cloud_controller_client).to_not be_nil
      expect(bootstrap.cloud_controller_client).to be_a_kind_of(Dea::CloudControllerClient)
    end
  end

  describe '#setup_staging_responders' do
    it 'initializes the generic and http staging responders' do
      bootstrap.setup_staging_responders
      expect(bootstrap.http_staging_responder).to_not be_nil
      expect(bootstrap.staging_responder).to_not be_nil
    end
  end

  describe 'download_buildpacks' do
    let(:buildpack_uri) { URI::join(@config['cc_url'], '/internal/buildpacks').to_s }

    before do
      @config['staging'] = { 'enabled' => true }
      @config['cc_url'] = 'https://user:password@api.example.com'
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

  describe '#stage_app_request' do
    let(:data) { {'foo' => 'bar'} }
    let(:evac_handler) { double('evac_handler', evacuating?: false) }
    let(:shutdown_handler) { double('shutdown_handler', shutting_down?: false) }

    before do
      allow(bootstrap).to receive(:evac_handler).and_return(evac_handler)
      allow(bootstrap).to receive(:shutdown_handler).and_return(shutdown_handler)

      allow(EM).to receive(:add_periodic_timer)
      bootstrap.setup_staging_responders
    end


    it "sends a staging request to the handler" do
      expect(bootstrap.http_staging_responder).to receive(:handle).with(data)
      bootstrap.stage_app_request(data)
    end
  end
end
