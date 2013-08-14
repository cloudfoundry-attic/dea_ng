require "spec_helper"
require "dea/container/container"

describe Dea::Container do
  let(:handle) { "fakehandle" }
  let(:socket_path) { "/tmp/warden.sock.notreally" }
  subject(:container) { described_class.new(socket_path, TEST_TEMP) }
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

  #describe "#handle" do
  #  it "returns the handle of the container" do
  #    expect(container.handle).to eq("17deadbeef")
  #  end
  #end

  describe "#get_connection" do
    context "when conneciton is cached" do
      before do
        container.cache_connection(connection_name, connection)
      end

      context "when connection is connected" do
        let(:connected) { true }
        it "uses cached connection" do
          expect(container.get_connection(connection_name)).to eq(connection)
        end
      end

      context "when connection is not connected" do
        let(:connected) { false }
        it "creates new connection" do
          Dea::Connection.should_receive(:new).with(connection_name, socket_path, TEST_TEMP).and_return(connection)
          container.get_connection(connection_name)
        end
      end
    end

    context "when connection is not cached" do
      before do
        Dea::Connection.should_receive(:new).with(connection_name, socket_path, TEST_TEMP).and_return(connection)
      end

      it "creates a new connection and caches it" do
        container.get_connection(connection_name)
        expect(container.find_connection(connection_name)).to eq(connection)
      end

      context "if connection fails" do
        let(:connection) { double("failing connection", :promise_create => failing_promise({})) }
        it "raises an error" do
          expect {
            container.get_connection(connection_name)
          }.to raise_error
        end
      end
    end
  end

  describe "#socket_path" do
    it "returns the socket of the container" do
      expect(container.socket_path).to eq("/tmp/warden.sock.notreally")
    end
  end

  describe "interacting with the container" do
    let(:client) { double("client") }

    # can't yield from root fiber, and this object is
    # assumed to be run from another fiber anyway
    around { |example| Fiber.new(&example).resume }

    before { container.stub(:client => client) }

    describe "#info" do
      let(:result) { double("result") }
      before do
        container.handle = handle
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
  end

  describe "keeping track of connections" do
    let(:connection_name) { "connection_name" }
    let(:connection) { double("fake connection") }

    describe "#find_connection" do
      before do
        container.cache_connection(connection_name, connection)
      end

      it "returns the connection associated with the name" do
        expect(container.find_connection(connection_name)).to eq(connection)
      end
    end

    describe "#cache_connection" do
      it "stores the connection" do
        container.cache_connection(connection_name, connection)
        expect(container.find_connection(connection_name)).to eq(connection)
      end
    end

    describe "#close_connection" do
      before do
        container.cache_connection(connection_name, connection)
      end

      it "closes the connection and removes it from the cache" do
        connection.should_receive(:close)

        container.close_connection(connection_name)

        expect(container.find_connection(connection_name)).to be_nil
      end
    end

    describe "#close_all_connections" do
      let(:connection_name_two) { "connection_name_two" }
      let(:connection_two) { double("fake connection two") }

      before do
        container.cache_connection(connection_name, connection)
        container.cache_connection(connection_name_two, connection_two)
      end

      it "closes all connections" do
        connection.should_receive(:close)
        connection_two.should_receive(:close)

        container.close_all_connections

        expect(container.find_connection(connection_name)).to be_nil
        expect(container.find_connection(connection_name_two)).to be_nil
      end
    end
  end

  describe "#call_with_retry" do
    before do
      container.cache_connection(connection_name, connection)
    end

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
end