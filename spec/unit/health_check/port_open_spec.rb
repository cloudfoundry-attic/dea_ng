# coding: UTF-8

require "spec_helper"
require "dea/health_check/port_open"
require "vcap/common"

describe Dea::HealthCheck::PortOpen do
  let(:host) { "127.0.0.1" }
  let(:port) { VCAP.grab_ephemeral_port }

  def start_server
    EM.start_server(host, port)
  end

  it "should succed if someone is listening on the port" do
    ok = run_health_check(host, port, 0.1) do
      start_server
    end

    ok.should be_true
  end

  it "should succed if someone starts listening on the port" do
    ok = run_health_check(host, port, 0.6) do
      EM.add_timer(0.04) { start_server }
    end

    ok.should be_true
  end

  it "should fail if no-one is listening on the port" do
    start = Time.now
    ok = run_health_check(host, port, 0.1)
    elapsed = Time.now - start

    ok.should be_false
    elapsed.should be_within(0.2).of(0.1)
  end

  def run_health_check(host, port, timeout, &blk)
    success = false
    health_check = nil

    em(:timeout => 1) do
      blk.call unless blk.nil?

      health_check = Dea::HealthCheck::PortOpen.new(host, port, 0.02) do |hc|
        hc.callback do
          success = true
          EM.stop
        end

        hc.errback do
          success = false
          EM.stop
        end

        hc.timeout(timeout)
      end
    end

    success
  end
end
