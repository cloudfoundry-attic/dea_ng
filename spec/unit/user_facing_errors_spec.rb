require "spec_helper"
require "dea/user_facing_errors"

module Dea
  describe HealthCheckFailed do
    describe "#to_s" do
      its(:to_s) { should == "failed to accept connections within health check timeout" }
    end
  end

  describe MissingStartCommand do
    describe "#to_s" do
      its(:to_s) { should == "missing start command" }
    end
  end
end
