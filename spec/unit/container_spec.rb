require "spec_helper"
require "dea/container"

describe Dea::Container do
  let(:handle) { "fakehandle" }
  let(:socket_path) { "/tmp/warden.sock.notreally" }

  subject(:container) { described_class.new(socket_path) }

  #describe "#handle" do
  #  it "returns the handle of the container" do
  #    expect(container.handle).to eq("17deadbeef")
  #  end
  #end

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
        connection.should_receive(:close_connection)

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
        connection.should_receive(:close_connection)
        connection_two.should_receive(:close_connection)

        container.close_all_connections

        expect(container.find_connection(connection_name)).to be_nil
        expect(container.find_connection(connection_name_two)).to be_nil
      end
    end
  end

end