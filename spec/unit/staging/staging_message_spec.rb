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
      "index" => 0
    }
  end

  let(:admin_buildpacks) { [] }

  let(:staging_message) do
    {
      "app_id" => "some-node-app-id",
      "task_id" => "task-id",
      "properties" => {"some_property" => "some_value"},
      "download_uri" => "http://localhost/unstaged/rails3_with_db",
      "upload_uri" => "http://localhost/upload/rails3_with_db",
      "buildpack_cache_download_uri" => "http://localhost/buildpack_cache/download",
      "buildpack_cache_upload_uri" => "http://localhost/buildpack_cache/upload",
      "admin_buildpacks" => admin_buildpacks,
      "start_message" => start_message,
    }
  end

  subject(:message) { StagingMessage.new(staging_message) }

  its(:app_id) { should eq "some-node-app-id" }
  its(:task_id) { should eq "task-id" }
  its(:download_uri) { should eq URI("http://localhost/unstaged/rails3_with_db") }
  its(:upload_uri) { should eq URI("http://localhost/upload/rails3_with_db") }
  its(:buildpack_cache_upload_uri) { should eq URI("http://localhost/buildpack_cache/upload") }
  its(:buildpack_cache_download_uri) { should eq URI("http://localhost/buildpack_cache/download") }
  its(:start_message) { should be_a StartMessage }
  its(:admin_buildpacks) { should eq([]) }
  its(:properties) { should eq("some_property" => "some_value") }
  its(:to_hash) { should eq staging_message }

  it "should memoize the start message" do
    expect(message.start_message).to eq(message.start_message)
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
  end
end