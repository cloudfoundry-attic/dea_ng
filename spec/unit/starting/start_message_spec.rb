require "spec_helper"
require "dea/starting/start_message"

describe StartMessage do
  let(:limits) { {"mem" => 64, "disk" => 128, "fds" => 32} }
  let(:uris) { ["http://www.someuri.com"] }
  let(:console) { false }
  let(:debug) { true }
  let(:services) { ["a_service"] }

  let(:start_message) do
    {
      "droplet" => "some-app-id",
      "name" => "some-app-name",
      "uris" => uris,
      "prod" => false,
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
    }
  end

  subject(:message) { StartMessage.new(start_message) }

  its(:index) { should eq 1 }
  its(:droplet) { should eq "some-app-id" }
  its(:version) { should eq "some-version" }
  its(:name) { should eq "some-app-name" }
  its(:uris) { should eq [URI("http://www.someuri.com")] }
  its(:prod) { should be_false }
  its(:executable_uri) { should eq URI("http://www.someuri.com") }
  its(:executable_file) { should eq "deprecated" }
  its(:cc_partition) { should eq "default" }
  its(:limits) { should eq limits }
  its(:mem_limit) { should eq 64 }
  its(:disk_limit) { should eq 128 }
  its(:fds_limit) { should eq 32 }
  its(:sha1) { should eq "foobar" }
  its(:services) { should eq(["a_service"]) }
  its(:env) { should eq([]) }
  its(:console) { should be_false }
  its(:debug) { should be_true }
  its(:start_command) { should eq "rails s -s $PORT" }
  its(:vcap_application) { should eq "message vcap_application" }
  its(:to_hash) { should eq start_message }

  context "when there is no limits" do
    before { start_message.delete("limits") }

    its(:mem_limit) { should be_nil }
    its(:disk_limit) { should be_nil }
    its(:fds_limit) { should be_nil }
  end

  context "when the limits are nil" do
    let(:limits) { nil }

    its(:mem_limit) { should be_nil }
    its(:disk_limit) { should be_nil }
    its(:fds_limit) { should be_nil }
  end

  context "when the limits is empty" do
    let(:limits) { {} }

    its(:mem_limit) { should be_nil }
    its(:disk_limit) { should be_nil }
    its(:fds_limit) { should be_nil }
  end

  context "when there are nil uris" do
    let(:uris) { nil }
    its(:uris) { should eq([]) }
  end

  context "when there are no uris" do
    before { start_message.delete("uris") }
    its(:uris) { should eq([]) }
  end

  context "when the list of uris is empty" do
    let(:uris) { [] }
    its(:uris) { should eq([]) }
  end

  context "when the debug option is not present" do
    let(:debug) { nil }
    its(:debug) { should be_false }
  end

  context "when the debug option is not present" do
    let(:console) { nil }
    its(:console) { should be_false }
  end

  context "when there are no services" do
    let(:services) { nil }
    its(:services) { should eq([]) }
  end

  context "since start messages are nested in staging messages, its possible to have an empty start message" do
    let(:start_message) { nil }

    its(:index) { should be_nil }
    its(:droplet) { should be_nil }
    its(:version) { should be_nil }
    its(:name) { should be_nil }
    its(:uris) { should eq([]) }
    its(:prod) { should be_false }
    its(:executable_uri) { should be_nil }
    its(:executable_file) { should be_nil }
    its(:cc_partition) { should be_nil }
    its(:limits) { should eq({}) }
    its(:mem_limit) { should be_nil }
    its(:disk_limit) { should be_nil }
    its(:fds_limit) { should be_nil }
    its(:sha1) { should be_nil }
    its(:services) { should eq([]) }
    its(:env) { should eq([]) }
    its(:console) { should be_false }
    its(:debug) { should be_false }
    its(:start_command) { should be_nil }
    its(:to_hash) { should eq({})}
    its(:vcap_application) { should eq({})}
  end
end
