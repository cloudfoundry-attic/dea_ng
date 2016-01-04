require "spec_helper"
require "container/warden_client_provider"

describe WardenClientProvider do
  let(:socket_path) { "/tmp/warden.sock.notreally" }
  let(:connection_name) { "connection_name" }
  let(:connected) { false }
  let(:response) { "response" }
  let(:connection) do
    double("fake connection",
      :name => connection_name,
      :connect => response,
      :connected? => connected
    )
  end

  subject(:client_provider) { described_class.new(socket_path) }

  describe "#get" do
    before do
      allow(EventMachine::Warden::FiberAwareClient).to receive(:new).with(socket_path).and_return(connection)
    end

    context "when connection is cached" do
      before do
        @client = client_provider.get(connection_name)
      end

      context "when connection is connected" do
        let(:connected) { true }
        it "uses cached connection" do
          expect(client_provider.get(connection_name)).to equal(@client)
        end
      end

      context "when connection is not connected" do
        let(:connected) { false }
        it "creates new connection" do
          allow(EventMachine::Warden::FiberAwareClient).to receive(:new).with(socket_path).and_return(connection)
          client_provider.get(connection_name)
        end
      end
    end

    context "when connection is not cached" do
      let(:connected) { false }
      before do
        allow(EventMachine::Warden::FiberAwareClient).to receive(:new).with(socket_path).and_return(connection)
      end

      it "creates a new connection and caches it" do
        client_provider.get(connection_name)
        expect(client_provider.get(connection_name)).to eq(connection)
      end

      context "if connection fails" do
        let(:connection) { double("failing connection") }

        it "raises an error" do
          allow(connection).to receive(:connect).and_raise("whoops")
          expect {
            client_provider.get(connection_name)
          }.to raise_error "whoops"
        end
      end
    end
  end

  describe "keeping track of connections" do
    describe "#close_all" do
      let(:connection_name_two) { "connection_name_two" }

      let(:connection_two) do
        double("fake connection 2",
          :name => connection_name_two,
          :connect => response,
          :disconnect => "disconnecting",
          :connected? => connected)
      end

      before do
        allow(EventMachine::Warden::FiberAwareClient).to receive(:new).
          with(socket_path).ordered.and_return(connection)
        allow(EventMachine::Warden::FiberAwareClient).to receive(:new).
          with(socket_path).ordered.and_return(connection_two)

        client_provider.get(connection_name)
        client_provider.get(connection_name_two)
      end

      it "closes all connections" do
        allow(connection).to receive(:disconnect)
        allow(connection_two).to receive(:disconnect)

        client_provider.close_all
      end

      it "removes the connections from the cache" do
        allow(connection).to receive(:disconnect)
        allow(connection_two).to receive(:disconnect)
        client_provider.close_all

        allow(EventMachine::Warden::FiberAwareClient).to receive(:new).ordered.
          with(socket_path).and_return(connection)

        client_provider.get(connection_name)
      end
    end
  end

end
