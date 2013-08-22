require "spec_helper"
require "dea/container/connection_provider"

describe Dea::ConnectionProvider do
  let(:socket_path) { "/tmp/warden.sock.notreally" }
  let(:connection_name) { "connection_name" }
  let(:connected) { false }
  let(:connection) do
    double("fake connection",
      :name => connection_name,
      :promise_create => delivering_promise,
      :connected? => connected)
  end

  before do
    Dea::Connection.stub(:new).with(connection_name, socket_path).and_return(connection)
  end

  subject(:connection_provider) { described_class.new(socket_path) }

  describe "#get" do
    context "when connection is cached" do
      before do
        @connection = connection_provider.get(connection_name)
      end

      context "when connection is connected" do
        let(:connected) { true }
        it "uses cached connection" do
          expect(connection_provider.get(connection_name)).to equal(@connection)
        end
      end

      context "when connection is not connected" do
        let(:connected) { false }
        it "creates new connection" do
          Dea::Connection.should_receive(:new).with(connection_name, socket_path).and_return(connection)
          connection_provider.get(connection_name)
        end
      end
    end

    context "when connection is not cached" do
      let(:connected) { false }
      before do
        Dea::Connection.should_receive(:new).with(connection_name, socket_path).and_return(connection)
      end

      it "creates a new connection and caches it" do
        connection_provider.get(connection_name)
        expect(connection_provider.get(connection_name)).to eq(connection)
      end

      context "if connection fails" do
        let(:connection) { double("failing connection", :promise_create => failing_promise({})) }
        it "raises an error" do
          expect {
            connection_provider.get(connection_name)
          }.to raise_error
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
          :promise_create => delivering_promise,
          :connected? => connected)
      end

      before do
        Dea::Connection.stub(:new).with(connection_name_two, socket_path).and_return(connection_two)

        connection_provider.get(connection_name)
        connection_provider.get(connection_name_two)
      end

      it "closes all connections" do
        connection.should_receive(:close)
        connection_two.should_receive(:close)

        connection_provider.close_all
      end

      it "removes the connections from the cache" do
        connection.stub(:close)
        connection_two.stub(:close)
        connection_provider.close_all

        Dea::Connection.should_receive(:new).with(connection_name, socket_path)
        Dea::Connection.should_receive(:new).with(connection_name_two, socket_path)

        connection_provider.get(connection_name)
        connection_provider.get(connection_name_two)
      end
    end
  end

end
