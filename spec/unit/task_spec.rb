# coding: UTF-8

require "spec_helper"
require "dea/task"

describe Dea::Task do
  include_context "tmpdir"

  let(:config) { { "warden_socket" => warden_socket, "base_dir" => TEST_TEMP } }
  let(:warden_socket) { "warden.socksies" }
  subject(:task) { Dea::Task.new(config) }

  describe "#container -" do
    it "creates a container" do
      Dea::Container.should_receive(:new).with(warden_socket, TEST_TEMP)
      task.container
    end

    describe "if it has been created" do
      it "should return the container" do
        container = task.container
        Dea::Container.should_not_receive(:new)
        expect(task.container).to eq(container)
      end
    end
  end

  describe "#promise_stop -" do
    let(:response) do
      mock("Warden::Protocol::StopResponse mock")
    end

    before do
      task.stub(:container_handle) { "handle" }
    end

    it "executes a StopRequest" do
      task.container.should_receive(:call) do |connection, request|
        expect(request).to be_kind_of(::Warden::Protocol::StopRequest)
        expect(request.handle).to eq("handle")
        expect(connection).to eq(:stop)

        response
      end

      expect {
        task.promise_stop.resolve
      }.to_not raise_error
    end

    it "raises error when the StopRequest fails" do
      task.container.should_receive(:call).and_raise(RuntimeError.new("error"))

      expect {
        task.promise_stop.resolve
      }.to raise_error(RuntimeError, /error/i)
    end
  end

  describe "#promise_limit_disk -" do
    let(:response) { "okay response" }
    before do
      task.stub(:disk_limit_in_bytes).and_return(1234)
      task.stub(:container_handle).and_return("handle")
    end

    it "should make a LimitDisk request" do
      task.container.should_receive(:call) do |connection, request|
        expect(connection).to eq(:app)
        expect(request).to be_kind_of(::Warden::Protocol::LimitDiskRequest)
        expect(request.handle).to eq("handle")
        expect(request.byte).to eq(1234)

        response
      end

      task.promise_limit_disk.resolve
    end

    it "raises an error when the request fails" do
      task.container.should_receive(:call).and_raise(RuntimeError.new("error"))

      expect {
        task.promise_limit_disk.resolve
      }.to raise_error(RuntimeError, /error/i)
    end
  end

  describe "#promise_limit_memory -" do
    let(:response) { "okay response" }

    before do
      task.stub(:memory_limit_in_bytes).and_return(1234)
      task.stub(:container_handle).and_return("handle")
    end

    it "should make a LimitMemory request on behalf of the container" do
      task.container.should_receive(:call) do |connection, request|
        expect(connection).to eq(:app)
        expect(request).to be_kind_of(::Warden::Protocol::LimitMemoryRequest)
        expect(request.handle).to eq("handle")
        expect(request.limit_in_bytes).to eq(1234)
        response
      end

      task.promise_limit_memory.resolve
    end

    it "raises an error when the request call fails" do
      task.container.should_receive(:call).and_raise(RuntimeError.new("error"))

      expect {
        task.promise_limit_memory.resolve
      }.to raise_error(RuntimeError, /error/i)
    end
  end

  describe "#consuming_memory?" do
    it "returns true" do
      expect(task.consuming_memory?).to be_true
    end
  end

  describe "#consuming_disk?" do
    it "returns true" do
      expect(task.consuming_disk?).to be_true
    end
  end
end
