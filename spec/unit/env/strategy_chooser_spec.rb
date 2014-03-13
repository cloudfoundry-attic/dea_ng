require "spec_helper"
require "dea/env/strategy_chooser"

module Dea
  class Env
    describe StrategyChooser do
      let(:task) { double }
      subject(:env_strategy_chooser) { StrategyChooser.new(message, task) }
      let(:strategy) { double("strategy")}

      before do
        allow(Staging::Env).to receive(:new).and_return(strategy)
        allow(Starting::Env).to receive(:new).and_return(strategy)
      end

      context "when a staging message is provided" do
        let(:message) { StagingMessage.new({}) }

        it "instantiates the staging strategy" do
          expect(env_strategy_chooser.strategy).to eq(strategy)
          expect(Staging::Env).to have_received(:new).with(message, task)
        end
      end

      context "when a non-staging message is provided" do
        let(:message) { double("non staging message") }

        it "instantiates the staging strategy" do
          expect(env_strategy_chooser.strategy).to eq(strategy)
          expect(Starting::Env).to have_received(:new).with(message, task)
        end
      end
    end
  end
end