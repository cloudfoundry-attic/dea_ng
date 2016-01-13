# coding: UTF-8

require "spec_helper"
require "yajl"
require "dea/health_check/state_file_ready"

describe Dea::HealthCheck::StateFileReady do
  include_context "tmpdir"

  let(:state_file_path) { File.join(tmpdir, "state.json") }

  it "fails if the file never exists" do
    expect(run_health_check(state_file_path, 0.1)).to eq("failure")
  end

  it "fails if the file exists but the state is never 'RUNNING'" do
    write_state_file(state_file_path, "CRASHED")
    expect(run_health_check(state_file_path, 0.1)).to eq("failure")
  end

  it "fails if the state file is corrupted" do
    File.open(state_file_path, "w+") { |f| f.write("{{{") }
    expect(run_health_check(state_file_path, 0.1)).to eq("failure")
  end

  it "succeeds if the file exists prior to starting the health check" do
    write_state_file(state_file_path, "RUNNING")
    expect(run_health_check(state_file_path, 0.1)).to eq("success")
  end

  it "succeeds if the file exists before the timeout" do
    create_file = lambda do
      EM.add_timer(0.04) do
        write_state_file(state_file_path, "RUNNING")
      end
    end
    expect(run_health_check(state_file_path, 0.1, &create_file)).to eq("success")
  end

  def run_health_check(path, timeout, &before_health_check)
    result = nil

    with_event_machine(:timeout => 1) do
      before_health_check.call unless before_health_check.nil?

      Dea::HealthCheck::StateFileReady.new(path, 0.02) do |hc|
        hc.callback do
          result = "success"
          EM.stop
        end

        hc.errback do
          result = "failure"
          EM.stop
        end

        hc.timeout(timeout)
      end
    end

    result
  end

  def write_state_file(path, state)
    File.open(path, "w+") do |f|
      f.write(Yajl::Encoder.encode({ "state" => state }))
    end
  end
end
