require "spec_helper"
require "dea/container/container"

describe Dea::Container do
  let(:handle) { "fakehandle" }
  let(:socket_path) { "/tmp/warden.sock.notreally" }

  subject(:container) { described_class.new(socket_path) }

  #describe "#handle" do
  #  it "returns the handle of the container" do
  #    expect(container.handle).to eq("17deadbeef")
  #  end
  #end

  describe "get_connection" do
    let(:connection_name) { "connection_name" }
    let(:connected) { false }
    let(:connection) { double("fake connection", :promise_create => delivering_promise, :connected? => connected) }

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
          Dea::Connection.should_receive(:new).with(connection_name, socket_path).and_return(connection)
          container.get_connection(connection_name)
        end
      end
    end

    context "when connection is not cached" do
      before do
        Dea::Connection.should_receive(:new).with(connection_name, socket_path).and_return(connection)
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

end