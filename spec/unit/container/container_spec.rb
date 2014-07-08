require 'spec_helper'
require 'container/container'

describe Container do
  let(:handle) { 'fakehandle' }
  let(:socket_path) { '/tmp/warden.sock.notreally' }

  let(:client_provider) { double('connection provider', get: connection) }
  subject(:container) { described_class.new(client_provider) }

  let(:request) { double('request') }
  let(:response) { double('response') }
  let(:connection_name) { 'connection_name' }
  let(:connected) { true }
  let(:connection) do
    double('fake connection',
      :name => connection_name,
      :promise_create => response,
      :connected? => connected)
  end

  before do
    container.handle = handle
  end

  describe '#close_all_connections' do
    it 'deletegates to connection provider' do
      client_provider.should_receive(:close_all)
      container.close_all_connections
    end
  end

  describe '#info' do
    # can't yield from root fiber, and this object is
    # assumed to be run from another fiber anyway
    around { |example| Fiber.new(&example).resume }

    it 'sends an info request to the container' do

      called = false
      connection.should_receive(:call) do |request|
        called = true
        expect(request).to be_a(::Warden::Protocol::InfoRequest)
        expect(request.handle).to eq(handle)
      end

      container.info

      expect(called).to be_true
    end

    context 'when the request fails' do
      it 'raises an exception' do
        connection.should_receive(:call).and_raise('foo')

        expect { container.info }.to raise_error('foo')
      end
    end
  end

  describe '#list' do
    it 'sends a list request to the container' do
      called = false
      connection.should_receive(:call) do |request|
        called = true
        expect(request).to be_a(::Warden::Protocol::ListRequest)
      end

      container.list
      expect(called).to be_true
    end
  end

  describe '#update_path_and_ip' do
    let(:container_path) { '/container/path' }
    let(:container_host_ip) { '1.7.goodip' }
    let(:info_response) { Warden::Protocol::InfoResponse.new(:container_path => container_path, :host_ip => container_host_ip) }

    it "makes warden InfoRequest, then updates and returns the container's path" do
      container.should_receive(:call).and_return do |name, request|
        expect(name).to eq(:info)
        expect(request.handle).to eq('fakehandle')
        info_response
      end

      container.update_path_and_ip
      expect(container.path).to eq(container_path)
      expect(container.host_ip).to eq(container_host_ip)
    end

    context 'when InfoRequest does not return a container_path in the response' do
      it 'raises error' do
        container.should_receive(:call).and_return(Warden::Protocol::InfoResponse.new)

        expect {
          container.update_path_and_ip
        }.to raise_error(RuntimeError, /container path is not available/)
      end
    end

    context 'when container handle is not set' do
      let(:handle) { nil }
      it 'raises error' do
        expect {
          container.update_path_and_ip
        }.to raise_error(ArgumentError, /container handle must not be nil/)
      end
    end
  end

  describe '#call_with_retry' do
    context 'when there is a connection error' do
      let(:error_msg) { 'error' }
      let(:connection_error) { ::EM::Warden::Client::ConnectionError.new(error_msg) }

      it 'should retry the call (which will get a new connection)' do
        container.should_receive(:call).with(connection_name, request).ordered.and_raise(connection_error)
        container.should_receive(:call).with(connection_name, request).ordered.and_raise(connection_error)
        container.should_receive(:call).with(connection_name, request).ordered.and_return(response)
        result = container.call_with_retry(connection_name, request)
        expect(result).to eq(response)
      end
    end

    context 'when the call succeeds' do
      it 'should succeed with one call and not log debug output or warnings' do
        container.should_receive(:call).with(connection_name, request).ordered.and_return(response)
        result = container.call_with_retry(connection_name, request)
        expect(result).to eq(response)
      end
    end

    context 'when there is an error other than a connection error' do
      let(:other_error) { ::EM::Warden::Client::Error.new(error_msg) }
      let(:error_msg) { 'error' }

      it 'raises the error' do
        container.should_receive(:call).with(connection_name, request).ordered.and_raise(other_error)

        expect {
          container.call_with_retry(connection_name, request)
        }.to raise_error(other_error)
      end
    end
  end

  describe '#call' do
    before do
      VCAP::Component.varz.synchronize do
        VCAP::Component.varz[:total_warden_response_time_in_ms] = 10
        VCAP::Component.varz[:warden_request_count] = 10
        VCAP::Component.varz[:warden_error_response_count] = 1
      end
    end
    it 'makes a request using connection#call' do
      connection.should_receive(:call).with(request).and_return(response)
      container.call(connection_name, request)
    end

    context "when the call passes" do
      subject(:the_call) do
        Timecop.freeze(Time.local(2014, 1, 1, 0, 0, 0)) do
          container.call(connection_name, request)
        end
      end

      before do
        connection.stub(:call) do
          Timecop.freeze(Time.local(2014, 1, 1, 0, 0, 10))
        end
      end

      it 'logs the response time to varz' do
        the_call

        expect(VCAP::Component.varz[:total_warden_response_time_in_ms]).to eq(10_010)
      end

      it 'logs the response count to varz' do
        the_call

        expect(VCAP::Component.varz[:warden_request_count]).to eq(11)
      end

      context "when there's no recorded total_warden_response_time_in_ms or total_warden_request_count" do
        before do
          VCAP::Component.varz.synchronize do
            VCAP::Component.varz[:total_warden_response_time_in_ms] = nil
            VCAP::Component.varz[:warden_request_count] = nil
          end
        end

        it "logs the values correctly" do
          the_call

          expect(VCAP::Component.varz[:total_warden_response_time_in_ms]).to eq(10_000)
          expect(VCAP::Component.varz[:warden_request_count]).to eq(1)
        end
      end
    end

    context 'when the call fails' do
      subject(:the_call) do
        Timecop.freeze(Time.local(2014, 1, 1, 0, 0, 0)) do
          expect{ container.call(connection_name, request) }.to raise_error("Hell")
        end
      end

      before do
        connection.stub(:call) do
          Timecop.freeze(Time.local(2014, 1, 1, 0, 0, 10))
          raise "Hell"
        end
      end

      it 'still logs the response time to varz' do
        the_call

        expect(VCAP::Component.varz[:total_warden_response_time_in_ms]).to eq(10010)
        expect(VCAP::Component.varz[:warden_request_count]).to eq(11)
      end

      it 'logs the failure to varz' do
        the_call

        expect(VCAP::Component.varz[:warden_error_response_count]).to eq(2)
      end
    end
  end

  describe '#run_script' do
    let(:script) { double('./citizien_kane') }
    let(:response) { double('response', :exit_status => 0) }
    let(:log_tag) { 'some-log-tag' }

    it 'calls call with the connection name and request' do
      container.should_receive(:call) do |name, request|
        expect(name).to eq(connection_name)

        expect(request).to be_an_instance_of(::Warden::Protocol::RunRequest)
        expect(request.handle).to eq(handle)
        expect(request.script).to eq(script)
        expect(request.privileged).to be_false
        expect(request.discard_output).to be_true
        expect(request.log_tag).to eq(log_tag)

        response
      end

      result = container.run_script(connection_name, script, false, true, log_tag)
      expect(result).to eq(response)
    end

    it 'respects setting of privileged to true' do
      container.should_receive(:call) do |_, request|
        expect(request.privileged).to eq(true)
        response
      end
      container.run_script(connection_name, script, true)
    end

    context 'when the exit status is > 0' do
      let(:exit_status) { 1 }
      let(:stdout) { 'HI' }
      let(:stderr) { "it's broken" }
      let(:data) { {:script => script, :exit_status => exit_status, :stdout => stdout, :stderr => stderr} }
      let(:response) { double('response', :exit_status => exit_status, :stdout => stdout, :stderr => stderr) }
      it 'raises a warden error' do #check that it's a warden error with the exit status
        container.should_receive(:call).and_return(response)
        expect {
          container.run_script(connection_name, script)
        }.to raise_error { |error|
          expect(error).to be_a(Container::WardenError)
          expect(error.message).to eq('Script exited with status 1')
          expect(error.result).to_not be_nil
          expect(error.result.exit_status).to eq(1)
          expect(error.result.stdout).to eq('HI')
          expect(error.result.stderr).to eq("it's broken")
        }
      end
    end
  end

  describe '#spawn' do
    let(:script) { './dostuffscript' }

    it 'executes a SpawnRequest' do
      resource_limits = ::Warden::Protocol::ResourceLimits.new

      container.should_receive(:call) do |name, request|
        expect(name).to eq(:app)
        expect(request).to be_kind_of(::Warden::Protocol::SpawnRequest)
        expect(request.script).to eq(script)
        expect(request.handle).to eq(container.handle)
        expect(request.rlimits).to eq(resource_limits)
        expect(request.discard_output).to be_true

        response
      end

      result = container.spawn(script, resource_limits)

      expect(result).to eq(response)
    end

    it 'allows resource_limits to be unspecified' do
      container.should_receive(:call) do |name, request|
        expect(name).to eq(:app)
        expect(request).to be_kind_of(::Warden::Protocol::SpawnRequest)
        expect(request.script).to eq(script)
        expect(request.handle).to eq(container.handle)
        expect(request.discard_output).to be_true

        response
      end

      result = container.spawn(script)

      expect(result).to eq(response)
    end
  end

  describe '#destroy!' do
    it 'sends a destroy request to warden server' do
      connection.should_receive(:call) do |request|
        expect(request).to be_kind_of(::Warden::Protocol::DestroyRequest)
        expect(request.handle).to eq(container.handle)

        response
      end
      container.destroy!
    end

    it "sets the container's handle to nil" do
      connection.stub(:call).and_return(response)

      expect { container.destroy! }.to change { container.handle }.to(nil)
    end

    it 'catches the EM::Warden::Client::Error' do
      connection.stub(:call).and_raise(::EM::Warden::Client::Error)
      expect {
        container.destroy!
      }.not_to raise_error

    end
  end

  describe '#setup_egress_rules' do
    let(:egress_rules) do
      [
        { 'protocol' => 'tcp', 'port' => '80', 'destination' => '198.41.191.47/1' },
        { 'protocol' => 'udp', 'port' => '53', 'destination' => '198.41.191.47/1' }
      ]
    end

    it 'makes a create network request for each rule' do
      client_provider.should_receive(:get).with(:app).and_return(connection)

      connection.should_receive(:call) do |request|
        expect(request).to be_an_instance_of(::Warden::Protocol::NetOutRequest)
        expect(request[:protocol]).to eq(::Warden::Protocol::NetOutRequest::Protocol::TCP)
        expect(request.handle).to eq(container.handle)
        double(:network_response)
      end

      connection.should_receive(:call) do |request|
        expect(request).to be_an_instance_of(::Warden::Protocol::NetOutRequest)
        expect(request[:protocol]).to eq(::Warden::Protocol::NetOutRequest::Protocol::UDP)
        expect(request.handle).to eq(container.handle)
        double(:network_response)
      end

      container.setup_egress_rules(egress_rules)
    end
  end

  describe '#setup_inbound_network' do
    it 'makes a create network request and returns the ports' do
      client_provider.should_receive(:get).with(:app).and_return(connection)
      connection.should_receive(:call) do |request|
        expect(request).to be_an_instance_of(::Warden::Protocol::NetInRequest)
        expect(request.handle).to eq(container.handle)
        double('network_response', host_port: 8765, container_port: 000)
      end

      container.setup_inbound_network

      expect(container.network_ports['host_port']).to eql(8765)
      expect(container.network_ports['container_port']).to eql(000)
    end
  end

  describe '#create_container' do
    let(:bind_mounts) { double('mounts') }
    let(:params) { {
      bind_mounts: bind_mounts,
      limit_cpu: 300,
      byte: 100,
      inode: 100,
      limit_memory: 200,
      setup_inbound_network: true,
      egress_rules: [{ 'protocol' => 'tcp', 'port' => '80', 'destination' => '198.41.191.47/1' }]
    } }

    it 'raises an error when a required parameter is missing' do
      required_params = [:bind_mounts, :limit_cpu, :byte, :inode, :limit_memory, :setup_inbound_network]

      required_params.each do |key|
        params_copy = params.dup
        params_copy.delete(key)
        expect {
          container.create_container(params_copy)
        }.to raise_error(ArgumentError, "expecting #{key.to_s} parameter to create container")
      end
    end

    it 'creates a new container with cpu, disk size in byte, disk inode limit, memory limit, and egress rules' do
      container.should_receive(:new_container_with_bind_mounts).with(bind_mounts)
      container.should_receive(:limit_cpu).with(params[:limit_cpu])
      container.should_receive(:limit_disk).with(byte: params[:byte], inode: params[:inode])
      container.should_receive(:limit_memory).with(params[:limit_memory])
      container.should_receive(:setup_inbound_network)
      container.should_receive(:setup_egress_rules).with(params[:egress_rules])

      container.create_container(params)
    end

    it 'does not create the network if not required' do
      params[:setup_inbound_network] = false

      container.stub(:new_container_with_bind_mounts)
      container.stub(:limit_cpu)
      container.stub(:limit_disk)
      container.stub(:limit_memory)
      container.stub(:setup_egress_rules)

      container.should_not_receive(:setup_inbound_network)
      container.create_container(params)
    end
  end

  describe '#new_container_with_bind_mounts' do
    let(:bind_mounts) do
      [
        {'src_path' => '/path/src', 'dst_path' => '/path/dst'},
        {'src_path' => '/path/a', 'dst_path' => '/path/b'}
      ]
    end

    let(:response) { double('response').as_null_object }

    before do
      connection.stub(:call).and_return(response)
    end

    before do
      container.handle = nil
    end

    it 'makes a CreateRequest with the provide paths_to_bind' do
      create_response = double('response', handle: handle)
      connection.should_receive(:call) do |request|
        #expect(request.name).to eq(:app)
        expect(request).to be_an_instance_of(::Warden::Protocol::CreateRequest)

        expect(request.bind_mounts.count).to eq(bind_mounts.size)
        request.bind_mounts.each do |bm|
          expect(bm).to be_an_instance_of(::Warden::Protocol::CreateRequest::BindMount)
          expect(bm.mode).to eq(::Warden::Protocol::CreateRequest::BindMount::Mode::RO)
        end

        expect(request.bind_mounts[0].src_path).to eq('/path/src')
        expect(request.bind_mounts[0].dst_path).to eq('/path/dst')
        expect(request.bind_mounts[1].src_path).to eq('/path/a')
        expect(request.bind_mounts[1].dst_path).to eq('/path/b')
        create_response
      end

      expect(container.handle).to_not eq(handle)
      container.new_container_with_bind_mounts(bind_mounts)
    end
  end

  describe '#resource_limits' do
    it 'returns a ::Warden::Protocol::ResourceLimits' do
      expect(container.resource_limits(nil, nil)).to be_a_kind_of(::Warden::Protocol::ResourceLimits)
    end

    it 'sets nofile resource limit' do
      file_descriptor_limit = 1999
      expect(container.resource_limits(file_descriptor_limit, nil).nofile).to eq(1999)
    end

    it 'sets nproc resource limit'do
      process_limit = 2001
      expect(container.resource_limits(nil, process_limit).nproc).to eq(2001)
    end
  end

  describe '#link' do
    it 'calls #call_with_retry correctly' do
      fake_response = "fake response"

      container.should_receive(:call_with_retry) do |name, request|
        expect(name).to eq(:link)
        expect(request).to be_an_instance_of(::Warden::Protocol::LinkRequest)
        expect(request.handle).to eq(container.handle)
        expect(request.job_id).to eq('FAKE_JOB_ID')

        fake_response
      end

      expect(container.link('FAKE_JOB_ID')).to eq(fake_response)
    end
  end

  describe '#link_or_raise' do
    let(:response) { double(exit_status: 0)}

    it 'calls link with the job_id' do
      expect(container).to receive(:link).with('foobar').and_return(response)
      container.link_or_raise('foobar')
    end

    context 'when link exit status is 0' do
      it 'returns the response' do
        container.stub(:link).and_return(response)
        expect(container.link_or_raise('foobar')).to eq(response)
      end
    end

    context 'when link exit status > 0' do
      let(:response) { double(exit_status: 127)}

      it 'raises a Container::WardenError' do
        container.stub(:link).and_return(response)
        expect {
          container.link_or_raise('foobar')
        }.to raise_error(Container::WardenError)
      end
    end
  end

  describe 'memory limiting' do
    it 'sets the memory limit' do
      limit_in_bytes = 100
      response = double('response', resolve: nil)
      connection.should_receive(:call) do |request|
        expect(request).to be_an_instance_of(::Warden::Protocol::LimitMemoryRequest)
        expect(request.limit_in_bytes).to eql(limit_in_bytes)
        response
      end
      container.limit_memory(limit_in_bytes)
    end
  end

  describe 'disk limiting' do
    it 'sets the disk bytes limit' do
      disk_limit_in_bytes = 100
      disk_limit_response = double('disk response', resolve: nil)
      connection.should_receive(:call) do |request|
        expect(request).to be_an_instance_of(::Warden::Protocol::LimitDiskRequest)
        expect(request.byte).to eql(disk_limit_in_bytes)

        disk_limit_response
      end
      container.limit_disk(byte: disk_limit_in_bytes)
    end

    it 'sets the disk inodes limit' do
      disk_inodes_limit = 100
      disk_inodes_limit_response = double('disk response', resolve: nil)
      connection.should_receive(:call) do |request|
        expect(request).to be_an_instance_of(::Warden::Protocol::LimitDiskRequest)
        expect(request.inode).to eql(disk_inodes_limit)

        disk_inodes_limit_response
      end
      container.limit_disk(inode: disk_inodes_limit)
    end
  end

  describe 'stream' do
    it 'streams the data' do
      callback = lambda {}
      connection.should_receive(:stream).with(request, &callback)
      container.stream(request, &callback)
    end
  end

  describe Container::WardenError do
    subject(:warden_error) { Container::WardenError.new('foo', 'FAKE_RESPONSE')}

    describe '#inspect' do
      it 'does not include response for security reason (not allowed to look into customer code / output)' do
        expect(warden_error.inspect).not_to include('FAKE_RESPONSE')
      end
    end
  end
end
