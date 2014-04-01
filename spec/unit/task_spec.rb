# coding: UTF-8

require "spec_helper"
require "dea/task"

describe Dea::Task do
  include_context "tmpdir"

  let(:config) { { "warden_socket" => warden_socket } }
  let(:warden_socket) { "warden.socksies" }
  let(:connection_provider) { double("connection provider")}

  before do
    WardenClientProvider.stub(:new).with(warden_socket).and_return(connection_provider)
  end

  subject(:task) { Dea::Task.new(config) }

  describe "#container -" do
    it "creates a container with connection provider" do
      Container.should_receive(:new).with(connection_provider)
      task.container
    end

    describe "if it has been created" do
      it "should return the container" do
        container = task.container
        Container.should_not_receive(:new)
        expect(task.container).to eq(container)
      end
    end
  end

  describe "#promise_stop -" do
    before { task.container.stub(:handle) { "handle" } }

    it "executes a StopRequest" do
      expect(task.container).to receive(:call).and_return(double(Warden::Protocol::StopResponse))

      expect {
        task.promise_stop.resolve
      }.to_not raise_error
    end

    context "when the stop request call fails" do
      it "fails the promise" do
        expect(task.container).to receive(:call).and_raise("Stop request failed")

        expect {
          task.promise_stop.resolve
        }.to raise_error("Stop request failed")
      end
    end

    context "when kill_flag is NOT passed" do
      it "generates a StopRequest with kill: false" do
        expect(task.container).to receive(:call) do |connection, request|
          expect(request).to be_kind_of(::Warden::Protocol::StopRequest)
          expect(request.handle).to eq("handle")
          expect(request.kill).to eq(false)
          expect(connection).to eq(:stop)
        end

        task.promise_stop.resolve
      end
    end

    context "when kill_flag is passed" do
      it "generates a StopRequest with kill: true" do
        expect(task.container).to receive(:call) do |connection, request|
          expect(request).to be_kind_of(::Warden::Protocol::StopRequest)
          expect(request.handle).to eq("handle")
          expect(request.kill).to eq(true)
          expect(connection).to eq(:stop)
        end

        task.promise_stop(true).resolve
      end
    end

    it "raises error when the StopRequest fails" do
      expect(task.container).to receive(:call).and_raise(RuntimeError.new("error"))

      expect {
        task.promise_stop.resolve
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
