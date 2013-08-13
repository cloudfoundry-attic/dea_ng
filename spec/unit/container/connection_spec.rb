require "spec_helper"
require "dea/container/connection"
require "dea/task"

describe Dea::Connection do
  include_context "tmpdir"

  let(:warden_socket) { File.join(tmpdir, "warden.sock") }

  let(:connection_name) { "fake_connection" }
  subject(:connection) {
    described_class.new(connection_name, warden_socket, TEST_TEMP)
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

  describe "#promise_call request" do
    let(:warden_connection) do
      warden_connection = double("warden_connection")
      warden_connection.stub(:call).and_yield(result)
      warden_connection
    end

    let(:request) { mock("mock request") }
    let(:result) { double("result", get: "Mock OK") }

    before do
      connection.instance_variable_set(:@warden_connection, warden_connection)
    end

    it "delivers response when request succeeds" do
      response = nil
      expect {
        response = connection.promise_call(request).resolve
      }.to_not raise_error
      expect(response).to eq("Mock OK")
    end

    context "when it fails" do
      let(:result_error) { RuntimeError.new("ERR FAKE") }
      before do
        result.should_receive(:get).and_raise(result_error)
      end

      it "fails when request fails" do
        response = nil
        FileUtils.should_receive(:touch)
        expect {
          response = connection.promise_call(request).resolve
        }.to raise_error(result_error)
        expect(response).to eq(nil)
      end

      context "when create file fails" do
        before do
          FileUtils.stub(:touch).and_raise(RuntimeError)
        end

        it "contains 'file touch: failed'" do
          connection.logger.should_receive(:warn).with(/file touched: failed/)
          expect {
            connection.promise_call(request).resolve
          }.to raise_error(result_error)
        end
      end

      context "when create file succeeds" do
        before { FileUtils.mkdir(File.join(TEST_TEMP, "tmp")) }

        it "contains 'file touch: passed'" do
          connection.logger.should_receive(:warn).with(/file touched: passed/)
          expect {
            connection.promise_call(request).resolve
          }.to raise_error(result_error)
        end
      end

      context "when Vmstat.snapshot fails" do
        before { Vmstat.stub(:snapshot).and_raise(RuntimeError) }

        it "contains 'file touch: failed'" do
          connection.logger.should_receive(:warn).with(/VMstat out: Unable to get Vmstat\.snapshot/)
          expect {
            connection.promise_call(request).resolve
          }.to raise_error(result_error)
        end
      end

      context "when Vmstat.snapshot succeeds" do
        it "contains 'file touch: passed'" do
          connection.logger.should_receive(:warn).with(/VMstat out: #<Vmstat::Snapshot:.+memory/)
          expect {
            connection.promise_call(request).resolve
          }.to raise_error(result_error)
        end
      end
    end
  end
end