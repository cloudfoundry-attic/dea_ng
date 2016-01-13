require "spec_helper"
require "dea/staging/staging_message"

describe StagingMessage do
  let(:start_message) do
    {
      "droplet" => "droplet-id",
      "name" => "name",
      "uris" => ["tnky1j0-buildpack-test.a1-app.cf-app.com"],
      "prod" => false,
      "sha1" => nil,
      "executableFile" => "deprecated",
      "executableUri" => nil,
      "version" => "version-number",
      "services" => [],
      "limits" => {
        "mem" => 64,
        "disk" => 1024,
        "fds" => 16384
      },
      "cc_partition" => "default",
      "env" => [],
      "console" => false,
      "debug" => nil,
      "start_command" =>
        nil,
      "index" => 0,
      "egress_network_rules" => nil,
      "vcap_application" => "vcap_app_thingy",
    }
  end

  let(:admin_buildpacks) { [] }
  let(:properties) do
    {
      "some_property" => "some_value",
      "services"      => ["servicethingy"],
      "environment"   => ["KEY=val"],
    }
  end
  let(:egress_network_rules) { [{ 'json' => 'data' }] }

  let(:staging_message) do
    {
      "app_id" => "some-node-app-id",
      "task_id" => "task-id",
      "properties" => properties,
      "download_uri" => "http://localhost/unstaged/rails3_with_db",
      "upload_uri" => "http://localhost/upload/rails3_with_db",
      "buildpack_cache_download_uri" => "http://localhost/buildpack_cache/download",
      "buildpack_cache_upload_uri" => "http://localhost/buildpack_cache/upload",
      "admin_buildpacks" => admin_buildpacks,
      "start_message" => start_message,
      "stack" => 'my-stack',
      "egress_network_rules" => egress_network_rules,
      "memory_limit" => 1024,
      "disk_limit" => 1024
    }
  end

  subject(:message) { StagingMessage.new(staging_message) }

  context "when the staging_message has memory_limit and disk_limit" do
    it "returns those values" do
      expect(message.mem_limit).to eq(staging_message['memory_limit'])
      expect(message.disk_limit).to eq(staging_message['disk_limit'])
    end
  end

  context "when the staging_message does not have memory_limit and disk_limit" do
    let(:staging_message) do
      {
        "app_id" => "some-node-app-id",
        "task_id" => "task-id",
        "properties" => properties,
        "download_uri" => "http://localhost/unstaged/rails3_with_db",
        "upload_uri" => "http://localhost/upload/rails3_with_db",
        "buildpack_cache_download_uri" => "http://localhost/buildpack_cache/download",
        "buildpack_cache_upload_uri" => "http://localhost/buildpack_cache/upload",
        "admin_buildpacks" => admin_buildpacks,
        "start_message" => start_message,
        "stack" => 'my-stack',
        "egress_network_rules" => egress_network_rules
      }
    end

    it "returns the limit values from the start message" do
      expect(message.mem_limit).to eq(start_message['limits']['mem'])
      expect(message.disk_limit).to eq(start_message['limits']['disk'])
    end
  end

  it "has the correct properties" do
    expect(message.app_id).to eq("some-node-app-id")
    expect(message.task_id).to eq("task-id")
    expect(message.download_uri).to eq(URI("http://localhost/unstaged/rails3_with_db"))
    expect(message.upload_uri).to eq(URI("http://localhost/upload/rails3_with_db"))
    expect(message.buildpack_cache_upload_uri).to eq(URI("http://localhost/buildpack_cache/upload"))
    expect(message.buildpack_cache_download_uri).to eq(URI("http://localhost/buildpack_cache/download"))
    expect(message.start_message).to be_a(StartMessage)
    expect(message.admin_buildpacks).to eq([])
    expect(message.properties).to eq({
        "some_property" => "some_value",
        "services"      => ["servicethingy"],
        "environment"   => ["KEY=val"],
    })
    expect(message.buildpack_git_url).to be_nil
    expect(message.buildpack_key).to be_nil
    expect(message.egress_rules).to eq([{ 'json' => 'data' }])
    expect(message.to_hash).to eq(staging_message)
    expect(message.env).to eq(['KEY=val'])
    expect(message.services).to eq(['servicethingy'])
    expect(message.vcap_application).to eq(start_message['vcap_application'])
    expect(message.stack).to eq(staging_message['stack'])
  end


  it "should memoize the start message" do
    expect(message.start_message).to eq(message.start_message)
  end

  context "when a custom buildpack url is specified" do
    context "when buildpack is used" do
      let (:properties) { {"buildpack" => "https://example.com/repo.git"} }

      its(:buildpack_git_url) { should eq(URI("https://example.com/repo.git")) }
    end

    context "when buildpack_git_url is used" do
      let (:properties) { {"buildpack_git_url" => "https://example.com/another_repo.git"} }

      its(:buildpack_git_url) { should eq(URI("https://example.com/another_repo.git")) }
    end

    context "when buildpack and buildpack_git_url are used" do
      let (:properties) do
        {
          "buildpack" => "https://example.com/repo.git",
          "buildpack_git_url" => "https://example.com/another_repo.git"
        }
      end

      it "should return the value associated with buildpack" do
        expect(message.buildpack_git_url).to eq(URI("https://example.com/repo.git"))
      end
    end
  end

  context "when admin build packs are specified" do
    let(:admin_buildpacks) do
      [
        {
          "url" => "http://www.example.com/buildpacks/uri/first",
          "key" => "first"
        },
        {
          "url" => "http://www.example.com/buildpacks/uri/second",
          "key" => "second"
        }
      ]
    end

    its(:admin_buildpacks) do
      should eq([
        {
          url: URI("http://www.example.com/buildpacks/uri/first"),
          key: "first"
        },
        {
          url: URI("http://www.example.com/buildpacks/uri/second"),
          key: "second"
        }
      ])
    end

    it "should handle invalid buildpack urls" do
      admin_buildpacks[0]["url"] = nil

      expect(message.admin_buildpacks).to eq([
        {
          url: URI("http://www.example.com/buildpacks/uri/second"),
          key: "second"
        }
      ])
    end
  end

  context "when a buildpack key is specified" do
    let(:properties) { {"buildpack_key" => "admin_buildpack_key"} }

    its(:buildpack_key) { should eq "admin_buildpack_key" }
  end

  context "when egress rules are not specified" do
    let(:egress_network_rules) { nil }
    its(:egress_rules) { should eq([]) }
  end
end
