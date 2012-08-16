# coding: UTF-8

require "spec_helper"
require "yajl"

require "dea/health_check/state_file_ready"

describe Dea::HealthCheck::StateFileReady do
  include_context "tmpdir"

  let(:state_file_path) { File.join(tmpdir, "state.json") }

  it "should fail if the file never exists" do
    start = Time.now
    ok = run_health_check(state_file_path, 0.1)
    elapsed = Time.now - start

    ok.should be_false
    elapsed.should be_within(0.02).of(0.1)
  end

  it "should fail if the file exists but the state is never 'RUNNING'" do
    write_state_file(state_file_path, "CRASHED")

    start = Time.now
    ok = run_health_check(state_file_path, 0.1)
    elapsed = Time.now - start

    ok.should be_false
    elapsed.should be_within(0.02).of(0.1)
  end

  it "should fail if the state file is corrupted" do
    File.open(state_file_path, "w+") { |f| f.write("{{{") }

    start = Time.now
    ok = run_health_check(state_file_path, 0.1)
    elapsed = Time.now - start

    ok.should be_false
    elapsed.should be_within(0.02).of(0.1)
  end

  it "should succeed if the file exists prior to starting the health check" do
    write_state_file(state_file_path, "RUNNING")

    run_health_check(state_file_path, 0.1).should be_true
  end

  it "should succeed if the file exists before the timeout" do
    ok = run_health_check(state_file_path, 0.1) do
      EM.add_timer(0.04) { write_state_file(state_file_path, "RUNNING") }
    end

    ok.should be_true
  end

  def run_health_check(path, timeout, &blk)
    success = false
    health_check = nil

    em(:timeout => 1) do
      blk.call unless blk.nil?

      health_check = Dea::HealthCheck::StateFileReady.new(path, 0.02) do |hc|
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

  def write_state_file(path, state)
    File.open(path, "w+") do |f|
      f.write(Yajl::Encoder.encode({ "state" => state }))
    end
  end
end
