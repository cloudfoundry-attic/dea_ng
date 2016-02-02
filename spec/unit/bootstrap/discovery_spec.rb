# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  before do
    allow(bootstrap).to receive(:setup_directory_server).and_call_original
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
