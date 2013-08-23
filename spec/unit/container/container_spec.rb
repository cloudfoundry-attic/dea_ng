require "spec_helper"
require "dea/container/container"

describe Dea::Container do
  let(:handle) { "fakehandle" }
  let(:socket_path) { "/tmp/warden.sock.notreally" }

  let(:connection_provider) { double('connection provider', get: connection)}
  subject(:container) { described_class.new(connection_provider) }

  let(:request) { double("request") }
  let(:response) { double("response") }
  let(:connection_name) { "connection_name" }
  let(:connected) { true }
  let(:connection) do
    double("fake connection",
           :name => connection_name,
           :promise_create => delivering_promise,
           :connected? => connected)
  end

  before do
    container.handle = handle
  end

  describe "#close_all_connections" do
    it "deletegates to connection provider" do
      connection_provider.should_receive(:close_all)
      container.close_all_connections
    end
  end

  describe "#info" do
    let(:client) { double("client", connect: nil) }
    # can't yield from root fiber, and this object is
    # assumed to be run from another fiber anyway
    around { |example| Fiber.new(&example).resume }

    let(:result) { double("result") }
    before do
      connection_provider.stub(:socket_path).and_return(socket_path)
      EventMachine::Warden::FiberAwareClient.stub(:new).and_return(client)
    end

    it "sends an info request to the container" do

      called = false
      client.should_receive(:call) do |request|
        called = true
        expect(request).to be_a(::Warden::Protocol::InfoRequest)
        expect(request.handle).to eq(handle)
      end

      container.info

      expect(called).to be_true
    end

    context "when the request fails" do
      it "raises an exception" do
        client.should_receive(:call).and_raise("foo")

        expect { container.info }.to raise_error("foo")
      end
    end
  end

  describe "#update_path_and_ip" do
    let(:container_path) { "/container/path" }
    let(:container_host_ip) { "1.7.goodip" }
    let(:info_response) { Warden::Protocol::InfoResponse.new(:container_path => container_path, :host_ip => container_host_ip) }

    it "makes warden InfoRequest, then updates and returns the container's path" do
      container.should_receive(:call).and_return do |name, request|
        expect(name).to eq(:info)
        expect(request.handle).to eq("fakehandle")
        info_response
      end

      container.update_path_and_ip
      expect(container.path).to eq(container_path)
      expect(container.host_ip).to eq(container_host_ip)
    end

    context "when InfoRequest does not return a container_path in the response" do
      it "raises error" do
        container.should_receive(:call).and_return(Warden::Protocol::InfoResponse.new)

        expect {
          container.update_path_and_ip
        }.to raise_error(RuntimeError, /container path is not available/)
      end
    end

    context "when container handle is not set" do
      let(:handle) { nil }
      it "raises error" do
        expect {
          container.update_path_and_ip
        }.to raise_error(ArgumentError, /container handle must not be nil/)
      end
    end
  end

  describe "#call_with_retry" do
    context "when there is a connection error" do
      let(:error_msg) { "error" }
      let(:connection_error) { ::EM::Warden::Client::ConnectionError.new(error_msg) }

      it "should retry the call (which will get a new connection)" do
        container.should_receive(:call).with(connection_name, request).ordered.and_raise(connection_error)
        container.should_receive(:call).with(connection_name, request).ordered.and_raise(connection_error)
        container.should_receive(:call).with(connection_name, request).ordered.and_return(response)
        container.logger.should_receive(:log_exception).twice
        container.logger.should_receive(:debug).with(/succeeded after 2/i)

        result = container.call_with_retry(connection_name, request)
        expect(result).to eq(response)
      end
    end

    context "when the call succeeds" do
      it "should succeed with one call and not log debug output or warnings" do
        container.should_receive(:call).with(connection_name, request).ordered.and_return(response)
        container.logger.should_not_receive(:debug)
        container.logger.should_not_receive(:warn)

        result = container.call_with_retry(connection_name, request)
        expect(result).to eq(response)
      end
    end

    context "when there is an error other than a connection error" do
      let(:other_error) { ::EM::Warden::Client::Error.new(error_msg) }
      let(:error_msg) { "error" }

      it "raises the error" do
        container.should_receive(:call).with(connection_name, request).ordered.and_raise(other_error)

        expect {
          container.call_with_retry(connection_name, request)
        }.to raise_error(other_error)
      end
    end
  end

  describe "#call" do
    it "calls #promise_call" do
      connection.should_receive(:promise_call).with(request).and_return(delivering_promise)
      container.call(connection_name, request)
    end
  end

  describe "#run_script" do
    let(:script) { double("./citizien_kane") }
    let(:response) { double("response", :exit_status => 0)}

    it "calls call with the connection name and request" do
      container.should_receive(:call) do |name, request|
        expect(name).to eq(connection_name)

        expect(request).to be_an_instance_of(::Warden::Protocol::RunRequest)
        expect(request.handle).to eq(handle)
        expect(request.script).to eq(script)
        expect(request.privileged).to eq(false)

        response
      end

      result = container.run_script(connection_name, script)
      expect(result).to eq(response)
    end

    it "respects setting of privileged to true" do
      container.should_receive(:call) do |_, request|
        expect(request.privileged).to eq(true)
        response
      end
      container.run_script(connection_name, script, true)
    end

    context "when the exit status is > 0" do
      let(:exit_status) { 1 }
      let(:stdout) { "HI" }
      let(:stderr) { "its broken" }
      let(:data) { {:script => script, :exit_status => exit_status, :stdout => stdout, :stderr => stderr }}
      let(:response) { double("response", :exit_status => exit_status, :stdout => stdout, :stderr => stderr)}
      it "fails the promise" do #check that it's a warden error with the exit status
        container.should_receive(:call).and_return(response)
        container.logger.should_receive(:warn).with(/exited with status/i, data)
        expect {
          container.run_script(connection_name, script)
        }.to raise_error(Dea::Container::WardenError, "Script exited with status 1")
      end
    end


  end

  describe "#spawn" do
    let(:nproc_limit) { 123 }
    let(:file_descriptor_limit) { 456 }
    let(:script) { "./dostuffscript" }

    it "executes a SpawnRequest" do
      container.should_receive(:call) do |name, request|
        expect(name).to eq(:app)
        expect(request).to be_kind_of(::Warden::Protocol::SpawnRequest)
        expect(request.handle).to eq(container.handle)
        expect(request.rlimits.nproc).to eq(nproc_limit)
        expect(request.rlimits.nofile).to eq(file_descriptor_limit)
        expect(request.script).to eq(script)

        response
      end
      result = container.spawn(script, file_descriptor_limit, nproc_limit)
      expect(result).to eq(response)
    end
  end

  describe "#destroy!" do
    let(:promise) { double("promise", resolve: nil)}

    it "sends a destroy request to warden server" do
      connection.should_receive(:promise_call) do |request|
        expect(request).to be_kind_of(::Warden::Protocol::DestroyRequest)
        expect(request.handle).to eq(container.handle)

        promise
      end
      container.destroy!
    end

    it "sets the container's handle to nil" do
      connection.stub(:promise_call).and_return(promise)

      expect { container.destroy! }.to change { container.handle }.to(nil)
    end

    it "catches and logs the EM::Warden::Client::Error" do
      connection.stub(:promise_call).and_raise(::EM::Warden::Client::Error)
      container.logger.should_receive(:warn)
      expect {
        container.destroy!
      }.not_to raise_error

    end
  end

  describe "#create_container" do
    let(:bind_mounts) do
      [
        { "src_path" => "/path/src", "dst_path" => "/path/dst" },
        { "src_path" => "/path/a", "dst_path" => "/path/b" }
      ]
    end

    let(:response) { double("response", :handle => handle) }
    before do
      container.handle = nil
    end

    it "makes a CreateRequest with the provide paths_to_bind, and returns the response" do
      container.should_receive(:call) do |name, request|
        expect(name).to eq(:app)
        expect(request).to be_an_instance_of(::Warden::Protocol::CreateRequest)

        expect(request.bind_mounts.count).to eq(bind_mounts.size)
        request.bind_mounts.each do |bm|
          expect(bm).to be_an_instance_of(::Warden::Protocol::CreateRequest::BindMount)
          expect(bm.mode).to eq(::Warden::Protocol::CreateRequest::BindMount::Mode::RO)
        end

        expect(request.bind_mounts[0].src_path).to eq("/path/src")
        expect(request.bind_mounts[0].dst_path).to eq("/path/dst")
        expect(request.bind_mounts[1].src_path).to eq("/path/a")
        expect(request.bind_mounts[1].dst_path).to eq("/path/b")
        response
      end

      expect(container.handle).to_not eq(handle)
      container.create_container(bind_mounts)
      expect(container.handle).to eq(handle)
    end
  end
end