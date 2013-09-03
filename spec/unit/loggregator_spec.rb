require "spec_helper"
require "dea/loggregator"

describe Dea::Loggregator do
  before(:each) do
    @emitter = FakeEmitter.new
    Dea::Loggregator.emitter = @emitter
  end

  describe ".emit" do
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

  describe ".emit_error" do
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
