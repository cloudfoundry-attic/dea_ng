require "spec_helper"
require "dea/user_facing_errors"

module Dea
  describe HealthCheckFailed do
    describe "#to_s" do
      it 'returns the failure string message' do
        expect(HealthCheckFailed.new.to_s).to eq "failed to accept connections within health check timeout"
      end
    end
  end

  describe MissingStartCommand do
    describe "#to_s" do
      it 'returns the failure string message' do
        expect(MissingStartCommand.new.to_s).to eq "missing start command"
      end
    end
  end
end
