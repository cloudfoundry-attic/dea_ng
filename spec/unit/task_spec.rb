# coding: UTF-8

require "spec_helper"
require "dea/task"

describe Dea::Task do
  include_context "tmpdir"

  let(:config) { Hash.new }
  subject(:task) { Dea::Task.new(config) }

  describe "#promise_warden_connection" do
    let(:warden_socket) { File.join(tmpdir, "warden.sock") }

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

    let(:config) { {"warden_socket" => warden_socket} }

    it "succeeds when connecting succeeds" do
      em do
        ::EM.start_unix_domain_server(warden_socket, dumb_connection)
        ::EM.next_tick do
          Dea::Promise.resolve(task.promise_warden_connection(:app)) do |error, result|
            expect do
              raise error if error
            end.to_not raise_error

            # Check that the connection was made
            dumb_connection.count.should == 1

            done
          end
        end
      end
    end

    it "succeeds when cached connection can be used" do
      em do
        ::EM.start_unix_domain_server(warden_socket, dumb_connection)
        ::EM.next_tick do
          Dea::Promise.resolve(task.promise_warden_connection(:app)) do |error, result|
            expect do
              raise error if error
            end.to_not raise_error

            # Check that the connection was made
            dumb_connection.count.should == 1

            Dea::Promise.resolve(task.promise_warden_connection(:app)) do |error, result|
              expect do
                raise error if error
              end.to_not raise_error

              # Check that the connection wasn't made _again_
              dumb_connection.count.should == 1

              done
            end
          end
        end
      end
    end

    it "fails when connecting fails" do
      em do
        Dea::Promise.resolve(task.promise_warden_connection(:app)) do |error, result|
          expect do
            raise error if error
          end.to raise_error(Dea::Task::WardenError, /cannot connect/i)

          done
        end
      end
    end
  end

  describe "#promise_warden_call" do
    let(:connection) do
      mock("Connection")
    end

    let(:request) do
      mock("Request")
    end

    let(:result) do
      mock("Result")
    end

    before do
      task.should_receive(:promise_warden_connection).and_return(delivering_promise(connection))
      connection.should_receive(:call).with(request).and_yield(result)
    end

    def resolve(&blk)
      em do
        promise = task.promise_warden_call(connection, request)
        Dea::Promise.resolve(promise, &blk)
      end
    end

    it "succeeds when request succeeds" do
      result.should_receive(:get).and_return("OK")

      resolve do |error, result|
        expect(error).to be_nil
        expect(result).to eq "OK"

        done
      end
    end

    context "when it fails" do
      before do
        result.should_receive(:get).and_raise(RuntimeError.new("ERR FAKE"))
        Vmstat.stub(:snapshot) { "vmstat" }
      end

      it "fails when request fails" do
        resolve do |error, _|
          expect(error).to_not be_nil

          done
        end
      end

      it "when system status for filesystem fails" do
        FileUtils.should_receive(:touch).and_raise(RuntimeError)
        task.logger.should_receive(:warn).with(/file\s+touched:\s+failed/)
        resolve { |_, _| done }
      end

      it "includes the system status" do
        FileUtils.should_receive(:touch).and_return(true)
        task.logger.should_receive(:warn).with(/.*file\s+touched:\s+pass.*vmstat/)
        resolve { |_, _| done }
      end
    end
  end

  describe "#promise_warden_call_with_retry" do
    let(:request) do
      mock("Request")
    end

    def resolve(&blk)
      em do
        promise = task.promise_warden_call_with_retry(:name, request)
        Dea::Promise.resolve(promise, &blk)
      end
    end

    def expect_success
      resolve do |error, result|
        expect do
          raise error if error
        end.to_not raise_error

        # Check result
        result.should == "ok"

        done
      end
    end

    def expect_failure
      resolve do |error, result|
        expect do
          raise error if error
        end.to raise_error(/error/)

        done
      end
    end

    it "succeeds when #promise_warden_call succeeds" do
      task.
        should_receive(:promise_warden_call).
        with(:name, request).
        and_return(delivering_promise("ok"))

      expect_success
    end

    it "fails when #promise_warden_call fails with ::EM::Warden::Client::Error" do
      task.
        should_receive(:promise_warden_call).
        with(:name, request).
        and_return(failing_promise(::EM::Warden::Client::Error.new("error")))

      expect_failure
    end

    it "retries when #promise_warden_call fails with ::EM::Warden::Client::ConnectionError" do
      task.
        should_receive(:promise_warden_call).
        with(:name, request).
        ordered.
        and_return(failing_promise(::EM::Warden::Client::ConnectionError.new("error")))

      task.
        should_receive(:promise_warden_call).
        with(:name, request).
        ordered.
        and_return(delivering_promise("ok"))

      expect_success
    end
  end

  describe "#promise_stop" do
    let(:response) do
      mock("Warden::Protocol::StopResponse")
    end

    before do
      task.stub(:container_handle) { "handle" }
    end

    it "executes a StopRequest" do
      task.stub(:promise_warden_call) do |connection, request|
        request.should be_kind_of(::Warden::Protocol::StopRequest)
        request.handle.should == "handle"

        delivering_promise(response)
      end

      expect { task.promise_stop.resolve }.to_not raise_error
    end

    it "can fail" do
      task.stub(:promise_warden_call) do
        failing_promise(RuntimeError.new("error"))
      end

      expect { task.promise_stop.resolve }.to raise_error(RuntimeError, /error/i)
    end
  end

  describe "#promise_limit_disk" do
    before do
      task.stub(:disk_limit_in_bytes).and_return(1234)
      task.stub(:container_handle).and_return("handle")
    end

    it "should make a LimitDisk request on behalf of the container" do
      task.stub(:promise_warden_call) do |connection, request|
        request.should be_kind_of(::Warden::Protocol::LimitDiskRequest)
        request.handle.should == "handle"
        request.byte.should == 1234
        delivering_promise
      end

      task.promise_limit_disk.resolve
    end

    it "raises an error when the warden call fails" do
      task.stub(:promise_warden_call) do
        failing_promise(RuntimeError.new("error"))
      end

      expect{ task.promise_limit_disk.resolve }.to raise_error(RuntimeError, /error/i)
    end
  end

  describe "#promise_limit_memory" do
    before do
      task.stub(:memory_limit_in_bytes).and_return(1234)
      task.stub(:container_handle).and_return("handle")
    end

    it "should make a LimitMemory request on behalf of the container" do
      task.stub(:promise_warden_call) do |connection, request|
        request.should be_kind_of(::Warden::Protocol::LimitMemoryRequest)
        request.handle.should == "handle"
        request.limit_in_bytes.should == 1234
        delivering_promise
      end

      task.promise_limit_memory.resolve
    end

    it "raises an error when the warden call fails" do
      task.stub(:promise_warden_call) do
        failing_promise(RuntimeError.new("error"))
      end

      expect{ task.promise_limit_memory.resolve }.to raise_error(RuntimeError, /error/i)
    end
  end
end
