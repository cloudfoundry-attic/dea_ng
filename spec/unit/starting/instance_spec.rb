require 'spec_helper'
require 'dea/starting/instance'

describe Dea::Instance do
  include_context 'tmpdir'

  let(:connection) { double('connection', :promise_call => delivering_promise) }
  let(:snapshot) do
    double('snapshot', :save => {})
  end
  let(:bootstrap) do
    double('bootstrap', :config => config, :snapshot => snapshot, local_ip: '1.1.1.1')
  end
  let(:rootfs) { '/path/to/rootfs' }
  let(:stack_name) { 'my-stack' }
  let(:stacks) do
    [
      {
        'name' => stack_name,
        'package_path' => rootfs,
      }
    ]
  end
  let(:config) do
    Dea::Config.new({ 'stacks' => stacks })
  end
  before do
    allow(bootstrap.config).to receive(:crashes_path).and_return('crashes/path')
  end

  subject(:instance) do
    Dea::Instance.new(bootstrap, valid_instance_attributes)
  end

  describe 'default attributes' do
    it 'defaults exit status to -1' do
      expect(instance.exit_status).to eq(-1)
    end
  end

  describe 'attributes from start message' do
    let(:start_message) do
      message = double('message')

      # Fixture to make sure Dea::Instance.create_from_message doesn't throw up
      defaults = {
          'index' => 0,
          'droplet' => 1,
      }

      allow(message).to receive(:data).and_return(defaults.merge(start_message_data))
      message
    end

    subject(:instance) do
      Dea::Instance.new(bootstrap, start_message.data)
    end

    describe 'instance attributes' do
      let(:start_message_data) do
        {
            'index' => 37,
        }
      end

      it "has an instance_id" do
        expect(instance.instance_id).to_not be_nil
      end

      it "has an instance index" do
        expect(instance.instance_index).to eq(37)
      end
    end

    describe 'application attributes' do
      let(:start_message_data) do
        {
            'droplet' => 37,
            'version' => 'some_version',
            'name' => 'my_application',
            'uris' => ['foo.com', 'bar.com'],
            'users' => ['john@doe.com'],
        }
      end

      it "has application attributes" do
        expect(instance.application_id).to eq('37')
        expect(instance.application_version).to eq('some_version')
        expect(instance.application_name).to eq('my_application')
        expect(instance.application_uris).to eq(['foo.com', 'bar.com'])
      end
    end

    describe 'droplet attributes' do
      let(:start_message_data) do
        {
            'sha1' => 'deadbeef',
            'executableUri' => 'http://foo.com/file.ext',
        }
      end

      it "has droplet attributes" do
        expect(instance.droplet_sha1).to eq('deadbeef')
        expect(instance.droplet_uri).to eq('http://foo.com/file.ext')
      end
    end

    describe 'start_command from message data' do
      let(:start_message_data) do
        {
            'start_command' => 'start command'
        }
      end

      it "has a start command" do
        expect(instance.start_command).to eq('start command')
      end

      context 'when the value is nil' do
        let(:start_message_data) do
          {
              'start_command' => nil
          }
        end

        it "has a nil start command" do
          expect(instance.start_command).to be_nil
        end
      end

      context 'when the key is not present' do
        let(:start_message_data) do
          {
          }
        end

        it "has a nil start command" do
          expect(instance.start_command).to be_nil
        end
      end
    end

    describe 'egress network rules' do
      context 'when egress network rules are missing' do
        let(:start_message_data) { {} }

        it "has a no egress rule" do
          expect(instance.egress_network_rules).to eq([])
        end
      end

      context 'when egress network rules are present' do
        let (:start_message_data) do
          {
            'egress_network_rules' => [
              { 'protocol' => 'tcp' },
              { 'port_range' => '80-443' }
            ]
          }
        end

        it "has an egress rule" do
          expect(instance.egress_network_rules).to match_array([{ 'protocol' => 'tcp' },{ 'port_range' => '80-443' }])
        end
      end
    end

    describe 'other attributes' do
      let(:start_message_data) do
        {
            'limits' => {'mem' => 1, 'disk' => 2, 'fds' => 3},
            'env' => ['FOO=BAR', 'BAR=', 'QUX'],
            'services' => {'name' => 'redis', 'type' => 'redis'},
        }
      end

      it "has other attributes" do
        expect(instance.limits).to eq({'mem' => 1, 'disk' => 2, 'fds' => 3})
        expect(instance.environment).to eq({'FOO' => 'BAR', 'BAR' => '', 'QUX' => ''})
        expect(instance.services).to eq({'name' => 'redis', 'type' => 'redis'})
      end
    end
  end

  describe 'attributes from snapshot' do
    describe 'container attributes' do
      let(:attributes) do
        valid_instance_attributes.merge(
            'warden_handle' => 'abc',
            'instance_host_port' => 1234,
            'instance_container_port' => 5678,
        )
      end

      subject { described_class.new(bootstrap, attributes) }

      it "has container attributes" do
        expect(subject.warden_handle).to eq('abc')
        expect(subject.instance_host_port).to eq(1234)
        expect(subject.instance_container_port).to eq(5678)
      end
    end
  end

  describe 'logging attributes' do
    let(:logger) do
      instance.instance_variable_get(:@logger)
    end
    subject { logger.user_data[:attributes].to_hash }
    it 'does not log sensitive attributes' do
      should_not include('services', 'droplet_uri', 'environment')
    end
  end

  describe 'resource limits' do
    it 'exports the memory limit in bytes' do
      expect(instance.memory_limit_in_bytes).to eq(512 * 1024 * 1024)
    end

    it 'exports the disk limit in bytes' do
      expect(instance.disk_limit_in_bytes).to eq(128 * 1024 * 1024)
    end

    it 'exports the file descriptor limit' do
      expect(instance.file_descriptor_limit).to eq(5000)
    end

    context 'when the nproc limit is set in the config' do
      let(:nproc_limit) {1024}
      let(:config) do
        Dea::Config.new(
          { 'stacks' => stacks,
            'instance' => {'nproc_limit' => nproc_limit }
          }
        )
      end

      it 'exports the correct nproc limit' do
        expect(instance.nproc_limit).to eq(nproc_limit)
      end
    end
  end

  describe 'validation' do
    it 'should not raise when the attributes are valid' do
      instance = Dea::Instance.new(bootstrap, valid_instance_attributes)

      expect { instance.validate }.to_not raise_error
    end

    it 'should raise when attributes are missing' do
      attributes = valid_instance_attributes.dup
      attributes.delete('application_id')
      attributes.delete('droplet')
      instance = Dea::Instance.new(bootstrap, attributes)

      expect { instance.validate }.to raise_error Membrane::SchemaValidationError
    end

    it 'should raise when attributes are invalid' do
      attributes = valid_instance_attributes.dup
      attributes['application_id'] = attributes['application_id'].to_i
      instance = Dea::Instance.new(bootstrap, attributes)

      expect { instance.validate }.to raise_error Membrane::SchemaValidationError
    end
  end

  describe 'state=' do
    it 'should set state_timestamp when invoked' do
      old_timestamp = instance.state_timestamp
      instance.state = Dea::Instance::State::RUNNING
      expect(instance.state_timestamp).to be > old_timestamp
    end
  end

  describe 'consuming_memory?' do
    states = Dea::Instance::State

    [states::BORN, states::STARTING, states::RUNNING,
     states::STOPPING].each do |state|
      context "when the state is #{state}" do
        before { instance.state = state }

        it 'returns true' do
          expect(instance.consuming_memory?).to be true
        end
      end
    end

    [states::STOPPED, states::CRASHED,
     states::RESUMING].each do |state|
      context "when the state is #{state}" do
        before { instance.state = state }

        it 'returns false' do
          expect(instance.consuming_memory?).to be false
        end
      end
    end
  end

  describe 'consuming_disk?' do
    states = Dea::Instance::State

    [states::BORN, states::STARTING, states::RUNNING,
     states::STOPPING, states::CRASHED].each do |state|
      context "when the state is #{state}" do
        before { instance.state = state }

        it 'returns true' do
          expect(instance.consuming_disk?).to be true
        end
      end
    end

    [states::STOPPED, states::RESUMING].each do |state|
      context "when the state is #{state}" do
        before { instance.state = state }

        it 'returns false' do
          expect(instance.consuming_disk?).to be false
        end
      end
    end
  end

  describe 'predicate methods' do
    it 'should be present for each state' do
      instance = Dea::Instance.new(bootstrap, {})
      instance.state = 'invalid'

      Dea::Instance::State.constants do |state|
        predicate = "#{state.downcase.to_s}?"

        expect(instance.send(predicate)).to be false
        instance.state = Dea::Instance::State.const_get(state)
        expect(instance.send(predicate)).to be true
      end
    end
  end

  describe '#emit_stats' do
    it 'triggers the stat collector to emit stats' do
      expect(instance.stat_collector).to receive(:emit_metrics).with(kind_of(Time))
      instance.emit_stats
    end
  end

  describe 'protected_attributes' do

    it 'does not include protected attributes' do
      expect(instance.protected_attributes.keys).to_not include('environment')
      expect(instance.protected_attributes.keys).to_not include('services')
    end
  end

  describe '#promise_health_check unit test' do
    let(:container_path) { 'fake/container/path' }

    before do
      instance.attributes['application_uris'] = []
      instance.container.handle = 'fake handle'
    end

    it 'updates the path and host ip' do
      expect(instance.container).to receive(:update_path_and_ip) do
        allow(instance.container).to receive(:path).and_return(container_path)
        allow(instance.container).to receive(:host_ip).and_return('fancy ip')
      end
      expect(instance).to receive(:promise_read_instance_manifest).with(container_path).and_return(delivering_promise(nil))

      instance.promise_health_check.resolve
      expect(instance.container.path).to eq(container_path)
      expect(instance.container.host_ip).to eq('fancy ip')
    end
  end

  describe '#used_memory_in_bytes' do
    it 'returns the value reported by stat_collector' do
      allow(instance.stat_collector).to receive(:used_memory_in_bytes).and_return(999)
      expect(instance.used_memory_in_bytes).to eq(999)
    end
  end

  describe '#promise_health_check' do
    let(:info_response) do
      info_response = double('InfoResponse')
      allow(info_response).to receive(:container_path).and_return('/')
      allow(info_response).to receive(:host_ip).and_return('127.0.0.1')
      info_response
    end

    let(:deferrable) do
      ::EM::DefaultDeferrable.new
    end

    before do
      allow(bootstrap).to receive(:local_ip).and_return('127.0.0.1')
      allow(instance.container).to receive(:update_path_and_ip)
      allow(instance.container).to receive(:host_ip).and_return(info_response.host_ip)
      allow(instance.container).to receive(:path).and_return(info_response.container_path)
      allow(instance).to receive(:promise_read_instance_manifest).and_return(delivering_promise({}))
      allow(instance).to receive(:instance_host_port).and_return(1234)
    end

    def execute_health_check
      error = result = nil

      with_event_machine do
        Dea::Promise.resolve(instance.promise_health_check) do |error_, result_|
          error, result = error_, result_
          done
        end

        yield if block_given?
      end

      expect do
        raise error if error
      end

      result
    end

    shared_examples 'sets timeout' do
      it 'sets timeout' do
        expect(deferrable).to receive(:timeout)
        execute_health_check do
          deferrable.succeed
        end
      end
    end

    describe 'via state file' do
      before do
        allow(instance).to receive(:promise_read_instance_manifest).and_return(delivering_promise({'state_file' => 'state_file.yml'}))
        allow(Dea::HealthCheck::StateFileReady).to receive(:new).and_yield(deferrable)
      end

      it 'sets a timeout of 5 minutes' do
        expect(deferrable).to receive(:timeout).with(60 * 5)
        execute_health_check do
          deferrable.succeed
        end
      end

      it 'can succeed' do
        result = execute_health_check do
          deferrable.succeed
        end

        expect(result).to be true
      end

      it 'can fail' do
        result = execute_health_check do
          deferrable.fail
        end

        expect(result).to be false
      end
    end

    describe 'when the application has URIs' do
      let(:application_id) { 37 }

      before do
        instance.attributes['application_id'] = application_id
        instance.attributes['application_uris'] = ['some-test-app.my-cloudfoundry.com']
        instance.attributes['instance_index'] = 2
        allow(Dea::HealthCheck::PortOpen).to receive(:new).and_yield(deferrable)

        @emitter = FakeEmitter.new
        Dea::Loggregator.emitter = @emitter
      end

      it 'succeeds when the port is open' do
        result = execute_health_check do
          deferrable.succeed
        end

        expect(result).to be true
      end

      it 'fails when the port is not open and logs an error message' do
        result = execute_health_check do
          deferrable.fail
        end

        expect(result).to be false
        expect(@emitter.error_messages[application_id][0]).to eql('Instance (index 2) failed to start accepting connections')
      end
    end

    describe 'when the application does not have any URIs' do
      before { instance.attributes['application_uris'] = [] }

      it 'should succeed' do
        result = execute_health_check
        expect(result).to be true
      end
    end

    context 'when failing to check the health' do
      let(:error) { RuntimeError.new('Some Error in warden') }

      before { allow(instance.container).to receive(:update_path_and_ip).and_raise(error) }

      subject { Dea::Promise.resolve(instance.promise_health_check) }

      it "doesn't raise an error" do
        expect {
          subject
        }.to_not raise_error
      end

      it 'should log the failure' do
        expect(instance.instance_variable_get(:@logger)).to receive(:error)
        subject
      end
    end

    context 'when health_check_timeout is specified in start request' do
      before { allow(Dea::HealthCheck::PortOpen).to receive(:new).and_yield(deferrable) }

      it 'should wait for specified timeout' do
        bootstrap.config['default_health_check_timeout'] = 100
        instance.attributes['health_check_timeout'] = 200
        expect(deferrable).to receive(:timeout).with(200)
        execute_health_check do
          deferrable.succeed
        end
      end
    end

    context 'when health_check_timeout is not specified' do
      before { allow(Dea::HealthCheck::PortOpen).to receive(:new).and_yield(deferrable) }

      it 'should use default' do
        bootstrap.config['default_health_check_timeout'] = 100
        expect(deferrable).to receive(:timeout).with(100)
        execute_health_check do
          deferrable.succeed
        end
      end
    end
  end

  describe 'start transition' do
    let(:droplet) do
      droplet = double('droplet')
      allow(droplet).to receive(:droplet_dirname).and_return(File.join(tmpdir, 'droplet', 'some_sha1'))
      allow(droplet).to receive(:droplet_basename).and_return('droplet.tgz')
      allow(droplet).to receive(:droplet_path).and_return(File.join(droplet.droplet_dirname, droplet.droplet_basename))
      droplet
    end

    let(:warden_connection) { double('warden_connection') }

    before do
      allow(instance).to receive(:promise_droplet).and_return(delivering_promise)
      allow(instance.container).to receive(:get_connection).and_raise('bad connection bad')
      allow(instance.container).to receive(:create_container)
      allow(instance).to receive(:promise_setup_environment).and_return(delivering_promise)
      allow(instance).to receive(:promise_extract_droplet).and_return(delivering_promise)
      allow(instance).to receive(:promise_prepare_start_script).and_return(delivering_promise)
      allow(instance).to receive(:promise_exec_hook_script).with('before_start').and_return(delivering_promise)
      allow(instance).to receive(:promise_start).and_return(delivering_promise)
      allow(instance).to receive(:promise_exec_hook_script).with('after_start').and_return(delivering_promise)
      allow(instance).to receive(:promise_health_check).and_return(delivering_promise(true))
      allow(instance).to receive(:droplet).and_return(droplet)
      allow(instance).to receive(:link)
    end

    def expect_start
      error = nil

      with_event_machine do
        instance.start do |error_|
          error = error_
          done
        end
      end

      raise error if error
    end

    describe 'checking source state' do
      passing_states = [Dea::Instance::State::BORN]

      passing_states.each do |state|
        it "passes when #{state.inspect}" do
          instance.state = state
          expect { expect_start }.to_not raise_error
        end
      end

      Dea::Instance::State.constants.map do |constant|
        Dea::Instance::State.const_get(constant)
      end.each do |state|
        next if passing_states.include?(state)

        it "fails when #{state.inspect}" do
          instance.state = state
          expect { expect_start }.to raise_error(Dea::Instance::BaseError, /transition/)
        end
      end
    end

    describe 'downloading droplet' do
      before { allow(instance).to receive(:promise_droplet).and_call_original }

      it 'succeeds when #download succeeds' do
        allow(droplet).to receive(:download).and_yield(nil)

        expect { expect_start }.to_not raise_error
        expect(instance.exit_description).to be_empty
      end

      it 'fails when #download fails' do
        msg = 'download failed'
        allow(droplet).to receive(:download).and_yield(Dea::Instance::BaseError.new(msg))

        expect { expect_start }.to raise_error(Dea::Instance::BaseError, msg)
      end
    end

    describe 'creating warden container' do
      let(:promise) { double(:creating_container_promise, resolve: nil) }

      it 'succeeds when the call succeeds' do
        instance.config['bind_mounts'] = [{'src_path' => '/var/src/', 'dst_path' => '/var/dst'}]
        instance.config['instance']['bandwidth_limit'] = { 'rate' => 1_000_000, 'burst' => 5_000_000 }

        expected_bind_mounts = [
            {'src_path' => droplet.droplet_dirname, 'dst_path' => droplet.droplet_dirname},
            {'src_path' => '/var/src/', 'dst_path' => '/var/dst'}
        ]
        expected_bandwidth_limit = { rate: 1_000_000, burst: 5_000_000 }
        with_network = true
        expect(instance.container).to receive(:create_container).
            with(bind_mounts: expected_bind_mounts,
                 limit_cpu: instance.cpu_shares,
                 byte: instance.disk_limit_in_bytes,
                 inode: instance.config.instance_disk_inode_limit,
                 limit_memory: instance.memory_limit_in_bytes,
                 setup_inbound_network: with_network,
                 egress_rules: instance.egress_network_rules,
                 rootfs: rootfs,
                 limit_bandwidth: expected_bandwidth_limit)
        expect { expect_start }.to_not raise_error
        expect(instance.exit_description).to be_empty
      end

      context "no rootfs" do
        before do
          config['stacks'] = []
        end
        it 'fails when the rootfs does not exist' do
          expect { expect_start }.to raise_error Dea::Instance::StackNotFoundError
        end
      end

      it 'fails when the call fails' do
        msg = 'promise warden call error for container creation'

        expect(instance.container).to receive(:create_container).and_raise(RuntimeError.new(msg))

        expect { expect_start }.to raise_error(RuntimeError, /error/i)
      end

      it "saves the created container's handle on attributes" do
        allow(instance.container).to receive(:create_container) do
          instance.container.handle = 'some-handle'
        end

        expect {
          expect { expect_start }.to_not raise_error
        }.to change {
          instance.attributes['warden_handle']
        }.from(nil).to('some-handle')
      end
    end

    describe 'cpu_shares' do
      before do
        instance.config['instance']['max_cpu_share_limit'] = 256
        instance.config['instance']['min_cpu_share_limit'] = 1
        instance.config['instance']['memory_to_cpu_share_ratio'] = 8
      end

      it 'is calculated from app memory divided by share_factor' do
        # app memory (512MB) / share factor (8)
        expect(instance.cpu_shares).to eq(64)
      end

      context 'when the calculated cpu shares exceed max_share_limit' do
        before do
          instance.config['instance']['max_cpu_share_limit'] = 2
        end

        it 'returns max_share_limit' do
          expect(instance.cpu_shares).to eq(2)
        end
      end

      context 'when the calculated cpu shares are below min_share_limit' do
        before do
          instance.config['instance']['min_cpu_share_limit'] = 726
        end

        it 'returns min_share_limit' do
          expect(instance.cpu_shares).to eq(726)
        end
      end
    end

    describe 'extracting the droplet' do
      before do
        allow(instance).to receive(:promise_extract_droplet).and_call_original
      end

      it 'should run tar' do
        allow(instance.container).to receive(:run_script) do |_, script|
          expect(script).to include 'tar zxf'
        end

        expect { expect_start }.to_not raise_error
        expect(instance.exit_description).to be_empty
      end

      it 'can fail by run failing' do
        msg = 'droplet extraction failure'
        allow(instance.container).to receive(:run_script) do |*_|
          raise RuntimeError.new(msg)
        end

        expect { expect_start }.to raise_error(msg)
      end
    end

    describe 'setting up environment' do
      before do
        allow(instance).to receive(:promise_setup_environment).and_call_original
      end

      it 'should create the app dir' do
        allow(instance.container).to receive(:run_script) do |_, script|
          expect(script).to include 'mkdir -p home/vcap/app'
        end

        expect { expect_start }.to_not raise_error
        expect(instance.exit_description).to be_empty
      end

      it 'should chown the app dir' do
        allow(instance.container).to receive(:run_script) do |_, script|
          expect(script).to include 'chown vcap:vcap home/vcap/app'
        end

        expect { expect_start }.to_not raise_error
        expect(instance.exit_description).to be_empty
      end

      it 'should remove existing and then symlink the app dir' do
        allow(instance.container).to receive(:run_script) do |_, script|
          expect(script).to include 'rm -rf /app && ln -s home/vcap/app /app'
        end

        expect { expect_start }.to_not raise_error
        expect(instance.exit_description).to be_empty
      end

      it 'can fail by run failing' do
        msg = 'environment setup failure'

        allow(instance.container).to receive(:run_script) do |*_|
          raise RuntimeError.new(msg)
        end

        expect { expect_start }.to raise_error(msg)
      end
    end

    shared_examples_for 'start script hook' do |hook|
      describe "#{hook} hook" do
        let(:runtime) do
          runtime = double(:runtime)
          allow(runtime).to receive(:environment).and_return({})
          runtime
        end

        before do
          allow(bootstrap).to receive(:config).and_return('hooks' => {hook => fixture("hooks/#{hook}")})
          allow(instance).to receive(:runtime).and_return(runtime)
          allow(instance).to receive(:promise_exec_hook_script).and_call_original
        end

        it 'should execute script file' do
          script_content = nil
          allow(instance.container).to receive(:run_script) do |_, script|
            expect(script).to_not be_empty
            lines = script.split("\n")
            script_content = lines[-2]
          end

          expect { expect_start }.to_not raise_error
          expect(instance.exit_description).to be_empty

          expect(script_content).to eq("echo \"#{hook}\"")
        end

        it 'should raise error when script execution fails' do
          msg = 'script execution failed'

          allow(instance.container).to receive(:run_script) do |_, script|
            raise RuntimeError.new(msg)
          end

          expect { expect_start }.to raise_error(msg)
        end
      end
    end

    it_behaves_like 'start script hook', 'before_start'
    it_behaves_like 'start script hook', 'after_start'

    describe '#promise_start' do
      let(:response) { double('spawn_response', job_id: 37) }
      let(:env) do
        double('environment 1',
               exported_environment_variables: 'system="sytem_value";\nexport user="user_value";\n',
               exported_user_environment_variables: 'user="user_value";\n',
               exported_system_environment_variables: 'system="sytem_value";\n'
        )
      end
      let(:generator) { double('script generator', generate: 'dostuffscript') }

      before do
        allow(instance).to receive(:promise_start).and_call_original
        allow(instance).to receive(:staged_info)
        instance.attributes['warden_handle'] = 'handle'
        allow(Dea::Env).to receive(:new).and_return(env)
        allow(Dea::StartupScriptGenerator).to receive(:new).and_return(generator)
        allow(instance.container).to receive(:update_path_and_ip)
      end

      context 'when the request fails' do
        before do
          allow(instance.container).to receive(:call).and_raise("can't start the application")
        end

        it 'raises an error' do
          expect {
            instance.promise_start.resolve
          }.to raise_error("can't start the application")
        end

        it 'does not set a job id' do
          expect {
            instance.promise_start.resolve rescue nil
          }.not_to change { instance.attributes['warden_job_id'] }.from(nil)
        end
      end

      context 'when there is a task info yaml in the droplet' do
        before do
          allow(instance).to receive(:staged_info).and_return('start_command' => 'fake_start_command.sh')
          allow(instance.container).to receive(:resource_limits).and_return('FAKE_RESOURCE_LIMIT_MESSAGE')
          allow(instance.container).to receive(:spawn).and_return(response)
        end

        context 'when a post-setup-hook is given in the config' do
          let(:config){Dea::Config.new({ 'stacks' => stacks, 'post_setup_hook' => 'post-setup-hook' })}

          it 'generates a script correctly' do
            expect(Dea::StartupScriptGenerator).to receive(:new).with(
            'fake_start_command.sh',
            env.exported_user_environment_variables,
            env.exported_system_environment_variables,
            'post-setup-hook',
            ).and_return(generator)

            instance.promise_start.resolve
          end
        end

        it 'applies the correct resource limits to the instance' do
          expect(instance.container).to receive(:resource_limits).with(
                                            instance.file_descriptor_limit,
                                            instance.nproc_limit
                                        ).and_return('FAKE_RESOURCE_LIMIT_MESSAGE')

          instance.promise_start.resolve
        end

        it 'generates the correct script and calls promise spawn' do
          expect(instance.container).to receive(:spawn)
          .with('dostuffscript', 'FAKE_RESOURCE_LIMIT_MESSAGE')
          .and_return(response)

          instance.promise_start.resolve
        end
      end

      context 'when there is a custom start command set on the instance' do
        subject(:instance) do
          Dea::Instance.new(
              bootstrap,
              valid_instance_attributes.merge('start_command' => 'my_custom_start_command.sh')
          )
        end

        shared_examples 'an instance with a custom start command' do
          before do
            allow(instance.container).to receive(:resource_limits).with(
                                             instance.file_descriptor_limit,
                                             instance.nproc_limit
                                         ).and_return('FAKE_RESOURCE_LIMIT_MESSAGE')
          end

          it 'uses the custom start command' do
            expect(instance.container).to receive(:spawn)
                                          .with('dostuffscript', 'FAKE_RESOURCE_LIMIT_MESSAGE')
                                          .and_return(response)

            instance.promise_start.resolve
          end
        end

        context 'and the buildpack does not provide a command' do
          before do
            allow(instance).to receive(:staged_info).and_return('start_command' => nil)
          end

          it_behaves_like 'an instance with a custom start command'
        end

        context 'and the buildpack provides one' do
          before do
            allow(instance).to receive(:staged_info).and_return('start_command' => 'foo')
          end

          it_behaves_like 'an instance with a custom start command'
        end
      end

      context 'when there is a staged_info but it lacks a start_command and instance lacks a start command' do
        before do
          allow(instance).to receive(:staged_info).and_return('start_command' => nil)
        end

        it 'fails to start' do
          expect {
            instance.promise_start.resolve
          }.to raise_error('missing start command')
        end
      end

      context 'when there is no task info yaml in the droplet only a startup script (old DEA)' do
        it 'runs the startup script instead of generating one' do
          allow(instance.container).to receive(:call) do |name, request|
            expect(request.script).to include('./startup')
            response
          end

          instance.promise_start.resolve
        end
      end

      context 'saving the snapshot' do
        before do
          allow(instance.container).to receive(:spawn).and_return(response)
        end

        it 'saves the snapshot' do
          expect(instance.container).to receive(:update_path_and_ip)
          expect(instance.bootstrap.snapshot).to receive(:save)
          instance.promise_start.resolve
        end
      end
    end

    describe 'checking application health' do
      before :each do
        allow(instance).to receive(:promise_state).with(Dea::Instance::State::BORN, Dea::Instance::State::STARTING).and_return(delivering_promise)
      end

      context 'when healthy' do
        before do
          allow(instance).to receive(:promise_health_check).and_return(delivering_promise(true))
        end

        it 'transitions from starting to running and emits stats' do
          expect(instance).to receive(:promise_state).with(Dea::Instance::State::STARTING, Dea::Instance::State::RUNNING).and_return(delivering_promise)
          expect(instance).to receive(:emit_stats)

          expect { expect_start }.to_not raise_error
          expect(instance.exit_description).to be_empty
        end
      end

      context 'when unhealthy' do
        before do
          allow(instance).to receive(:promise_health_check).and_return(delivering_promise(false))
        end

        it 'fails' do
          expect { expect_start }.to raise_error Dea::HealthCheckFailed

          # Instance exit description should be set to the failure message
          expect(instance.exit_description).to eq(Dea::HealthCheckFailed.new.to_s)
        end
      end
    end

    context 'when link fails' do
      before do
        allow(instance).to receive(:link).and_call_original
        allow(instance.container).to receive(:call_with_retry).with(:link, anything) do
          double('response', :exit_status => 255, :info => double('info', :events => ['out of memory']))
        end

        allow(instance).to receive(:promise_state).and_return(delivering_promise)
      end

      it 'sets exit description based on link response' do
        instance.start
        expect(instance.exit_description).to eq('out of memory')
      end
    end

    context 'when an arbitrary error occurs' do
      before { allow(instance).to receive(:link) { raise 'heck' } }

      it 'sets a generic exit description' do
        instance.start
        expect(instance.exit_description).to eq('failed to start')
      end
    end
  end

  describe 'stop transition' do
    let(:connection) { double('connection', :promise_call => delivering_promise) }

    let(:env) { double('environment').as_null_object }

    before do
      allow(bootstrap).to receive(:config).and_return({})
      allow(instance).to receive(:promise_state).and_return(delivering_promise)
      allow(instance.container).to receive(:get_connection).and_return(connection)
      allow(instance).to receive(:promise_stop).and_return(delivering_promise)
      allow(Dea::Env).to receive(:new).and_return(env)
    end

    def expect_stop
      error = nil

      with_event_machine do
        instance.stop do |error_|
          error = error_
          done
        end
      end

      expect do
        raise error if error
      end
    end

    describe 'checking source state' do
      before do
        allow(instance).to receive(:promise_state).and_call_original
      end

      passing_states = [Dea::Instance::State::BORN, Dea::Instance::State::STOPPING, Dea::Instance::State::RUNNING,
        Dea::Instance::State::EVACUATING, Dea::Instance::State::STARTING, Dea::Instance::State::STOPPED]

      passing_states.each do |state|
        it "passes when #{state.inspect}" do
          instance.state = state
          expect_stop.to_not raise_error
        end
      end

      Dea::Instance::State.constants.map do |constant|
        Dea::Instance::State.const_get(constant)
      end.each do |state|
        next if passing_states.include?(state)

        it "fails when #{state.inspect}" do
          instance.state = state
          expect_stop.to raise_error(Dea::Instance::BaseError, /transition/)
        end
      end
    end

    shared_examples_for 'stop script hook' do |hook|
      describe 'script hook' do
        let(:runtime) do
          runtime = double(:runtime)
          allow(runtime).to receive(:environment).and_return({})
          runtime
        end

        let(:env) { double('environment', exported_environment_variables: "export A=B;\n") }

        before do
          allow(Dea::Env).to receive(:new).with(instance).and_return(env)
          allow(bootstrap).to receive(:config).and_return('hooks' => {hook => fixture("hooks/#{hook}")})
          instance.state = Dea::Instance::State::RUNNING
        end

        it "executes the #{hook} script file" do
          script_content = nil
          allow(instance.container).to receive(:run_script) do |_, script|
            lines = script.split("\n")
            script_content = lines[-2]
          end
          expect_stop.to_not raise_error
          expect(script_content).to eq("echo \"#{hook}\"")
        end

        it 'exports the variables in the hook files' do
          actual_script_content = nil
          allow(instance.container).to receive(:run_script) do |_, script|
            actual_script_content = script
          end
          expect_stop.to_not raise_error
          expect(actual_script_content).to match /export A=B/
        end
      end
    end

    it_behaves_like 'stop script hook', 'before_stop'
    it_behaves_like 'stop script hook', 'after_stop'
  end

  describe '#promise_link' do
    let(:exit_status) { 42 }
    let(:info_events) { [] }

    let(:info_response) do
      double('Warden::Protocol::InfoResponse').tap do |info|
        allow(info).to receive(:events).and_return(info_events)
      end
    end

    let(:response) do
      response = double('Warden::Protocol::LinkResponse')
      allow(response).to receive(:exit_status).and_return(exit_status)
      allow(response).to receive(:info).and_return(info_response)
      response
    end

    describe 'when the LinkRequest fails' do
      it 'propagates the exception' do
        expect(instance.container).to receive(:call_with_retry).and_raise(RuntimeError, /error/i)

        expect {
          instance.promise_link.resolve
        }.to raise_error(RuntimeError, /error/i)
      end

      it 'causes the promise to fail, for the resolver of the promise (sanity check)' do
        expect(instance.container).to receive(:call_with_retry).and_raise(RuntimeError.new('error'))
        instance.link
        expect(instance.exit_status).to eq(-1)
      end
    end

    describe 'when the LinkRequest completes successfully' do
      let(:exit_status) { 42 }

      before do
        allow(instance.container).to receive(:call_with_retry).and_return(response)
      end

      it 'executes a LinkRequest with the warden handle and job ID and returns response' do
        instance.container.handle = 'handle'
        instance.attributes['warden_job_id'] = '1'
        expect(instance.container).to receive(:call_with_retry) do |name, request|
          expect(name).to eq(:link)
          expect(request).to be_kind_of(::Warden::Protocol::LinkRequest)
          expect(request.handle).to eq('handle')
          expect(request.job_id).to eq('1')

          response
        end

        result = instance.promise_link.resolve
        expect(result).to eq(response)
      end
    end
  end

  context "when resuming an instance in stopping state" do
    before do
      instance.state = Dea::Instance::State::RESUMING
      instance.setup
    end

    it "immediately links, and then stops the instance" do
      expect(instance).to receive(:link).and_call_original
      expect(instance).to receive(:stop)
      instance.state = Dea::Instance::State::STOPPING
    end
  end

  describe '#link' do
    let(:exit_status) { 42 }
    let(:info_events) { nil }

    let(:info_response) do
      double('Warden::Protocol::InfoResponse').tap do |info|
        allow(info).to receive(:events).and_return(info_events)
      end
    end

    let(:response) do
      response = double('Warden::Protocol::LinkResponse')
      allow(response).to receive(:exit_status).and_return(exit_status)
      allow(response).to receive(:info).and_return(info_response)
      response
    end

    before do
      instance.state = Dea::Instance::State::RUNNING
      allow(instance.container).to receive(:get_connection).and_return(connection)
      allow(instance).to receive(:promise_link).and_return(delivering_promise(response))
      expect(instance.exit_status).to eq(-1)
      expect(instance.exit_description).to eq('')
    end

    [
        Dea::Instance::State::RESUMING,
    ].each do |state|
      it "is triggered link when transitioning from #{state.inspect}" do
        instance.state = state
        instance.setup_link

        expect(instance).to receive(:link)
        instance.state = Dea::Instance::State::RUNNING
      end
    end

    describe 'when #promise_link succeeds' do
      it 'sets the exit status on the instance' do
        instance.link
        expect(instance.exit_status).to eq(exit_status)
      end

      context 'when the container_info has an event' do
        let(:info_events) { ['some weird thing happened'] }

        it 'sets the exit_description to the text of the event' do
          instance.link
          expect(instance.exit_description).to eq('some weird thing happened')
        end
      end

      context 'when the info_response is missing' do
        let(:info_response) { nil }

        it "sets the exit_description to 'cannot be determined'" do
          instance.link
          expect(instance.exit_description).to eq('cannot be determined')
        end
      end

      context 'when there is an info_response no usable information' do
        it "sets the exit_description to 'out of memory'" do
          instance.link
          expect(instance.exit_description).to eq('app instance exited')
        end
      end
    end

    context 'when the #promise_link fails' do
      before do
        expect(instance).to receive(:promise_link).and_return(failing_promise(RuntimeError.new('error')))
      end

      it 'sets exit status of the instance to -1' do
        instance.link
        expect(instance.exit_status).to eq(-1)
      end

      it 'sets exit description of the instance to unknown' do
        instance.link
        expect(instance.exit_description).to eq('unknown')
      end
    end

    describe 'state transitions' do
      [
          Dea::Instance::State::STARTING,
          Dea::Instance::State::RUNNING,
      ].each do |from|
        to = Dea::Instance::State::CRASHED

        it "changes to #{to.inspect} when it was #{from.inspect}" do
          instance.state = from

          expect {
            instance.link
          }.to change(instance, :state).to(to)
        end
      end

      [
          Dea::Instance::State::STOPPING,
          Dea::Instance::State::STOPPED,
      ].each do |from|
        it "doesn't change when it was #{from.inspect}" do
          instance.state = from

          expect {
            instance.link
          }.to_not change(instance, :state)
        end
      end
    end
  end

  describe 'destroy' do
    let(:connection) { double('connection', :promise_call => delivering_promise) }

    before do
      allow(instance.container).to receive(:get_connection).and_return(connection)
    end

    def expect_destroy
      error = nil

      with_event_machine do
        instance.destroy do |error_|
          error = error_
          done
        end
      end

      expect do
        raise error if error
      end
    end

    describe '#promise_destroy' do
      it 'executes a DestroyRequest' do
        instance.container.handle = 'handle'

        expect(instance.container).to receive(:call_with_retry) do |_, request|
          expect(request).to be_kind_of(::Warden::Protocol::DestroyRequest)
          expect(request.handle).to eq('handle')
        end

        expect_destroy.to_not raise_error
      end
    end
  end

  describe 'health checks' do
    let(:manifest_path) do
      File.join(tmpdir, 'rootfs', 'home', 'vcap', 'droplet.yaml')
    end

    before :each do
      FileUtils.mkdir_p(File.dirname(manifest_path))
    end

    describe '#promise_read_instance_manifest' do
      it 'delivers {} if no container path is returned' do
        expect(instance.promise_read_instance_manifest(nil).resolve).to eq({})
      end

      it "delivers {} if the manifest path doesn't exist" do
        expect(instance.promise_read_instance_manifest(tmpdir).resolve).to eq({})
      end

      it 'delivers the parsed manifest if the path exists' do
        manifest = {'test' => 'manifest'}
        File.open(manifest_path, 'w+') { |f| YAML.dump(manifest, f) }

        expect(instance.promise_read_instance_manifest(tmpdir).resolve).to eq(manifest)
      end
    end
  end

  describe 'crash handler' do
    before do
      instance.setup_crash_handler
      instance.state = Dea::Instance::State::RUNNING
      allow(instance).to receive(:promise_copy_out).and_return(delivering_promise)
      allow(instance).to receive(:promise_destroy).and_return(delivering_promise)
    end

    def expect_crash_handler
      error = nil

      with_event_machine do
        instance.crash_handler do |error_|
          error = error_
          done
        end
      end

      expect do
        raise error if error
      end
    end

    [Dea::Instance::State::RESUMING,
     Dea::Instance::State::RUNNING,
     Dea::Instance::State::STARTING,
    ].each do |state|
      it "is triggered link when transitioning from #{state.inspect}" do
        instance.state = state

        expect(instance).to receive(:crash_handler)
        instance.state = Dea::Instance::State::CRASHED
      end
    end

    describe 'when triggered' do
      before do
        instance.container.handle = 'handle'
      end

      it 'should resolve #promise_copy_out' do
        expect(instance).to receive(:promise_copy_out).and_return(delivering_promise)
        expect_crash_handler.to_not raise_error
      end

      it 'should resolve #promise_destroy' do
        expect(instance).to receive(:promise_destroy).and_return(delivering_promise)
        expect_crash_handler.to_not raise_error
      end

      it 'should close warden connections' do
        expect(instance.container).to receive(:close_all_connections)

        expect_crash_handler.to_not raise_error
      end
    end

    describe '#promise_copy_out' do
      before do
        allow(instance).to receive(:promise_copy_out).and_call_original
      end

      it 'should copy the contents of a logs directory' do
        expect(instance.container).to receive(:call_with_retry) do |_, request|
          expect(request.src_path).to match %r!/logs/$!
          expect(request.dst_path).to match %r!/crashes/path/.*/logs$!
        end

        instance.promise_copy_out.resolve
      end
    end
  end

  describe '#staged_info' do
    before do
      allow(instance).to receive(:copy_out_request)
    end

    context 'when the files does exist' do
      before do
        allow(YAML).to receive(:load_file).and_return(a: 1)
        allow(File).to receive(:exists?).
            with(match(/staging_info\.yml/)).
            and_return(true)
      end

      it 'sends copying out request' do
        expect(instance).to receive(:copy_out_request).with('/home/vcap/staging_info.yml', instance_of(String))
        instance.staged_info
      end

      it 'reads the file from the copy out' do
        expect(YAML).to receive(:load_file).with(/.+staging_info\.yml/)
        expect(instance.staged_info).to eq(a: 1)
      end

      it 'should only be called once' do
        expect(YAML).to receive(:load_file).once
        instance.staged_info
        instance.staged_info
      end
    end

    context 'when the yaml file does not exist' do
      it 'returns nil' do
        expect(instance.staged_info).to be_nil
      end
    end

    it "doesn't pollute the temp directory" do
      tmpdir = Dir.tmpdir

      old_size = Dir.glob(File.join(tmpdir, '**', '*'), File::FNM_DOTMATCH).size
      instance.staged_info

      expect(Dir.glob(File.join(tmpdir, '**', '*'), File::FNM_DOTMATCH).size).to be <= old_size
    end
  end

  describe '#instance_path' do
    context 'when state is CRASHED' do
      before { instance.state = Dea::Instance::State::CRASHED }

      context 'when warden_container_path is set' do
        before { allow(instance.container).to receive(:path).and_return('/root/dir') }

        it 'returns container path' do
          expect(instance.instance_path).to eq('/root/dir/tmp/rootfs/home/vcap')
        end
      end

      context 'when warden_container_path is not set' do
        it 'raises' do
          expect {
            instance.instance_path
          }.to raise_error('Warden container path not present')
        end
      end
    end

    context 'when state is RUNNING' do
      before { instance.state = Dea::Instance::State::RUNNING }
      context 'when warden_container_path is set' do
        before { allow(instance.container).to receive(:path).and_return('/root/dir') }

        it 'returns container path' do
          expect(instance.instance_path).to eq('/root/dir/tmp/rootfs/home/vcap')
        end
      end

      context 'when warden container path is not set' do
        it 'raises' do
          expect {
            instance.instance_path
          }.to raise_error('Warden container path not present')
        end
      end
    end

    context 'when state is STARTING' do
      before { instance.state = Dea::Instance::State::STARTING }

      it 'raises' do
        expect {
          instance.instance_path
        }.to raise_error('Instance path unavailable')
      end
    end
  end

  describe 'recovering from a snapshot' do
    it "sets the container's warden handle" do
      instance = described_class.new(bootstrap,
                                     valid_instance_attributes.merge(
                                         'warden_handle' => 'abc'))

      expect(instance.container.handle).to eq('abc')
    end

    it "sets the container's network ports" do
      instance = described_class.new(bootstrap,
                                     valid_instance_attributes.merge(
                                         'instance_host_port' => 1234,
                                         'instance_container_port' => 5678))

      expect(instance.instance_host_port).to eq(1234)
      expect(instance.instance_container_port).to eq(5678)
    end
  end

end
