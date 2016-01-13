# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  before do
    allow(bootstrap).to receive(:setup_directory_server).and_call_original
  end

  it "should publish a message on 'vcap.component.announce' on startup" do
    allow(bootstrap).to receive(:start_component).and_call_original

    announcement = nil
    nats_mock.subscribe("vcap.component.announce") do |msg|
      announcement = Yajl::Parser.parse(msg)
      done
    end

    with_event_machine(:timeout => 1) do
      bootstrap.setup
      bootstrap.start
    end

    expect(announcement).to_not be_nil
  end

  it "should publish a message on 'dea.start' on startup" do
    allow(bootstrap).to receive(:start_finish).and_call_original

    start = nil
    nats_mock.subscribe("dea.start") do |msg|
      start = Yajl::Parser.parse(msg)
      done
    end

    with_event_machine(:timeout => 1) do
      bootstrap.setup
      bootstrap.start
    end

    verify_hello_message(bootstrap, start)
  end

  it "should respond to messages on 'dea.status' with enhanced hello messages" do
    status = nil
    nats_mock.subscribe("result") do |msg|
      status = Yajl::Parser.parse(msg)
      done
    end

    with_event_machine(:timeout => 1) do
      bootstrap.setup
      bootstrap.start

      nats_mock.publish("dea.status", {}, "result")
    end

    verify_status_message(bootstrap, status)
  end

  def discover_message(opts = {})
    { "runtime" => "test1",
      "droplet" => 0,
      "limits"  => {
        "mem"  => 10,
        "disk" => 10,
      }
    }.merge(opts)
  end

  def verify_hello_message(bootstrap, hello)
    expect(hello).to_not be_nil
    expect(hello["id"]).to eq(bootstrap.uuid)
    expect(hello["ip"]).to eq(bootstrap.local_ip)
    expect(hello["version"]).to eq(Dea::VERSION)
  end

  def verify_status_message(bootstrap, status)
    verify_hello_message(bootstrap, status)

    %W[max_memory reserved_memory used_memory num_clients].each do |k|
      expect(status.has_key?(k)).to be true
    end
  end
end
