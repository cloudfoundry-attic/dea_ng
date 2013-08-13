require "spec_helper"
require "dea/container/connection"
require "dea/task"

describe Dea::Connection do
  include_context "tmpdir"

  let(:warden_socket) { File.join(tmpdir, "warden.sock") }

  let(:connection_name) { "fake_connection" }
  subject(:connection) {
    described_class.new(connection_name, warden_socket)
  }

  describe "#initialize" do
    it "creates a new connection" do
      expect(connection.name).to eq(connection_name)
      expect(connection.socket).to eq(warden_socket)
    end
  end

  describe "#promise_create" do
    let(:dumb_connection) do
      dumb_connection = Class.new(::EM::Connection) do
        class << self
          attr_accessor :count
        end

        def post_init
          self.class.count ||= 0
          self.class.count += 1
        end
      end
    end

    it "creates a connection, delivers the connection, and doesn't raise errors" do
      Dea::Task.new({ "warden_socket" => warden_socket })
      em do
        ::EM.start_unix_domain_server(warden_socket, dumb_connection)
        ::EM.next_tick do
          Dea::Promise.resolve(connection.promise_create) do |error, result|
            expect { raise error if error }.to_not raise_error
            expect(result).to be_instance_of(::EM::Warden::Client::Connection)
            # Check that the connection was made
            dumb_connection.count.should == 1
            done
          end
        end
      end
    end

    it "fails when connecting fails" do
      em do
        Dea::Promise.resolve(connection.promise_create) do |error, result|
          expect do
            raise error if error
          end.to raise_error(Dea::Connection::WardenError, /cannot connect/i)
          expect(result).to be_nil
          done
        end
      end
    end
  end
end