require "spec_helper"
require "dea/loggregator"

class ThrowingEmitter
  def initialize(err)
    @err = err
  end

  def emit(*args)
    raise @err
  end
end

describe Dea::Loggregator do
  before(:each) do
    @emitter = FakeEmitter.new
    @staging_emitter = FakeEmitter.new
    Dea::Loggregator.emitter = @emitter
    Dea::Loggregator.staging_emitter = @staging_emitter
  end

  describe "dea emitter" do
    describe "emitting when emitter throws Errno::ENETUNREACH" do
      it "doesn't raise" do
        @emitter = ThrowingEmitter.new(Errno::ENETUNREACH)
        @staging_emitter = ThrowingEmitter.new(Errno::ENETUNREACH)
        Dea::Loggregator.emitter = @emitter
        Dea::Loggregator.staging_emitter = @staging_emitter

        expect {
          Dea::Loggregator.emit("my_app_id", "important log message")
          Dea::Loggregator.staging_emit("my_app_id", "important log message")
        }.to_not raise_error
      end
    end
    describe "#emit" do
      it "emits to the loggregator" do
        Dea::Loggregator.emit("my_app_id", "important log message")
        expect(@emitter.messages["my_app_id"].length).to eql(1)
        expect(@emitter.messages["my_app_id"][0]).to eql("important log message")
      end

      it "does not emit if there is no loggregator" do
        Dea::Loggregator.emitter = nil
        Dea::Loggregator.emit("my_app_id", "important log message")
        expect(@emitter.messages["my_app_id"]).to be_nil
      end

      it "does not emit if there is no loggregator" do
        Dea::Loggregator.emit(nil, "important log message")
        expect(@emitter.messages.length).to eql(0)
      end
    end

    describe "#emit_error" do
      it "emits to the loggregator" do
        Dea::Loggregator.emit_error("my_app_id", "important log message")
        expect(@emitter.error_messages["my_app_id"].length).to eql(1)
        expect(@emitter.error_messages["my_app_id"][0]).to eql("important log message")
      end

      it "does not emit if there is no loggregator" do
        Dea::Loggregator.emitter = nil
        Dea::Loggregator.emit_error("my_app_id", "important log message")
        expect(@emitter.error_messages["my_app_id"]).to be_nil
      end

      it "does not emit if there is no loggregator" do
        Dea::Loggregator.emit_error(nil, "important log message")
        expect(@emitter.error_messages.length).to eql(0)
      end
    end
  end

  describe "#emit_value" do
    it "emits to the loggregator" do
      Dea::Loggregator.emit_value("my-value-metric", 10, 'my-units')
      expect(@emitter.messages["my-value-metric"].length).to eql(1)
      expect(@emitter.messages["my-value-metric"][0][:value]).to eq(10)
      expect(@emitter.messages["my-value-metric"][0][:unit]).to eq('my-units')
    end

    it "does not emit if there is no loggregator" do
      Dea::Loggregator.emitter = nil
      Dea::Loggregator.emit_value("my-value-metric", 10, 'my-units')
      expect(@emitter.messages["my-value-metric"]).to be_nil
    end
  end

  describe "#emit_counter" do
    it "emits to the loggregator" do
      Dea::Loggregator.emit_counter("my-counter", 10)
      expect(@emitter.messages["my-counter"].length).to eql(1)
      expect(@emitter.messages["my-counter"][0][:delta]).to eq(10)
    end

    it "does not emit if there is no loggregator" do
      Dea::Loggregator.emitter = nil
      Dea::Loggregator.emit_counter("my-counter", 10)
      expect(@emitter.messages["my-counter"]).to be_nil
    end
  end

  describe "#emit_container_metric" do
    it "emits to the loggregator" do
      Dea::Loggregator.emit_container_metric("app-id-1", 0, 0.5, 3, 5)
      expect(@emitter.messages["app-id-1"].length).to eql(1)
      expect(@emitter.messages["app-id-1"][0][:instanceIndex]).to eq(0)
      expect(@emitter.messages["app-id-1"][0][:cpuPercentage]).to eq(0.5)
      expect(@emitter.messages["app-id-1"][0][:memoryBytes]).to eq(3)
      expect(@emitter.messages["app-id-1"][0][:diskBytes]).to eq(5)
    end

    it "does not emit if there is no loggregator" do
      Dea::Loggregator.emitter = nil
      Dea::Loggregator.emit_container_metric("app-id-1", 0, 0.5, 3, 5)
      expect(@emitter.messages["app-id-1"]).to be_nil
    end
  end

  describe "staging emitter" do
    describe "#emit" do
      it "emits to the loggregator" do
        Dea::Loggregator.staging_emit("my_app_id", "important log message")
        expect(@staging_emitter.messages["my_app_id"].length).to eql(1)
        expect(@staging_emitter.messages["my_app_id"][0]).to eql("important log message")
      end

      it "does not emit if there is no loggregator" do
        Dea::Loggregator.staging_emitter = nil
        Dea::Loggregator.staging_emit("my_app_id", "important log message")
        expect(@staging_emitter.messages["my_app_id"]).to be_nil
      end
    end

    describe "#emit_error" do
      it "emits to the loggregator" do
        Dea::Loggregator.staging_emit_error("my_app_id", "important log message")
        expect(@staging_emitter.error_messages["my_app_id"].length).to eql(1)
        expect(@staging_emitter.error_messages["my_app_id"][0]).to eql("important log message")
      end

      it "does not emit if there is no loggregator" do
        Dea::Loggregator.staging_emitter = nil
        Dea::Loggregator.staging_emit_error("my_app_id", "important log message")
        expect(@staging_emitter.error_messages["my_app_id"]).to be_nil
      end
    end
  end
end
