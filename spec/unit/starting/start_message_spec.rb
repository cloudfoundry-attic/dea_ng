require "spec_helper"
require "dea/starting/start_message"

describe StartMessage do
  let(:limits) { {"mem" => 64, "disk" => 128, "fds" => 32} }
  let(:uris) { ["http://www.someuri.com"] }
  let(:console) { false }
  let(:debug) { true }
  let(:services) { ["a_service"] }
  let(:stack) { 'my-stack' }
  let(:egress_network_rules) { ["a" => "rule"] }

  let(:start_message) do
    {
      "droplet" => "some-app-id",
      "name" => "some-app-name",
      "uris" => uris,
      "sha1" => "foobar",
      "executableFile" => "deprecated",
      "executableUri" => "http://www.someuri.com",
      "version" => "some-version",
      "services" => services,
      "limits" => limits,
      "cc_partition" => "default",
      "env" => [],
      "console" => console,
      "debug" => debug,
      "start_command" => "rails s -s $PORT",
      "index" => 1,
      "vcap_application" => "message vcap_application",
      "egress_network_rules" => egress_network_rules,
      "stack" => stack,
    }
  end

  subject(:message) { StartMessage.new(start_message) }

  it "has attributes" do
    expect(message.index).to eq 1
    expect(message.droplet).to eq "some-app-id"
    expect(message.version).to eq "some-version"
    expect(message.name).to eq "some-app-name"
    expect(message.uris).to eq [URI("http://www.someuri.com")]
    expect(message.executable_uri).to eq URI("http://www.someuri.com")
    expect(message.executable_file).to eq "deprecated"
    expect(message.cc_partition).to eq "default"
    expect(message.limits).to eq limits
    expect(message.mem_limit).to eq 64
    expect(message.disk_limit).to eq 128
    expect(message.fds_limit).to eq 32
    expect(message.sha1).to eq "foobar"
    expect(message.services).to eq(["a_service"])
    expect(message.env).to eq([])
    expect(message.console).to be false
    expect(message.debug).to be true
    expect(message.start_command).to eq "rails s -s $PORT"
    expect(message.vcap_application).to eq "message vcap_application"
    expect(message.to_hash).to eq start_message
    expect(message.egress_network_rules).to eq(["a" => "rule"])
    expect(message.stack).to eq stack
    end

  context "when there is no limits" do
    before { start_message.delete("limits") }

    it "has no limits" do
      expect(message.mem_limit).to be_nil
      expect(message.disk_limit).to be_nil
      expect(message.fds_limit).to be_nil
    end
  end

  context "when the limits are nil" do
    let(:limits) { nil }

    it "has no limits" do
      expect(message.mem_limit).to be_nil
      expect(message.disk_limit).to be_nil
      expect(message.fds_limit).to be_nil
    end
  end

  context "when the limits is empty" do
    let(:limits) { {} }

    it "has no limits" do
      expect(message.mem_limit).to be_nil
      expect(message.disk_limit).to be_nil
      expect(message.fds_limit).to be_nil
    end
  end

  context "when there are nil uris" do
    let(:uris) { nil }

    it 'has no uris' do
      expect(message.uris).to eq([])
    end
  end

  context "when there are no uris" do
    before { start_message.delete("uris") }

    it 'has no uris' do
      expect(message.uris).to eq([])
    end
  end

  context "when the list of uris is empty" do
    let(:uris) { [] }

    it 'has no uris' do
      expect(message.uris).to eq([])
    end
  end

  context "when the debug option is not present" do
    let(:debug) { nil }

    it 'should be false' do
      expect(message.debug).to be false
    end
  end

  context "when the console option is not present" do
    let(:console) { nil }

    it 'should be false' do
      expect(message.console).to be false
    end
  end

  context "when there are no services" do
    let(:services) { nil }

    it 'should be empty' do
      expect(message.services).to eq([])
    end
  end

  context "when there are no egress network rules" do
    let(:egress_network_rules) { nil }

    it 'should be empty' do
      expect(message.egress_network_rules).to eq([])
    end
  end

  context "when there is no start message" do
    let(:start_message) { nil }

    it 'has no values' do
      expect(message.index).to be_nil
      expect(message.droplet).to be_nil
      expect(message.version).to be_nil
      expect(message.name).to be_nil
      expect(message.uris).to eq([])
      expect(message.executable_uri).to be_nil
      expect(message.executable_file).to be_nil
      expect(message.cc_partition).to be_nil
      expect(message.limits).to eq({})
      expect(message.mem_limit).to be_nil
      expect(message.disk_limit).to be_nil
      expect(message.fds_limit).to be_nil
      expect(message.sha1).to be_nil
      expect(message.services).to eq([])
      expect(message.env).to eq([])
      expect(message.console).to be false
      expect(message.debug).to be false
      expect(message.start_command).to be_nil
      expect(message.to_hash).to eq({})
      expect(message.vcap_application).to eq({})
      expect(message.egress_network_rules).to eq([])
    end
  end
end
