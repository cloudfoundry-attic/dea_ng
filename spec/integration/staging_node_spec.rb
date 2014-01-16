require "spec_helper"
require "net/http"

describe "Staging a node app", :type => :integration, :requires_warden => true do
  let(:unstaged_url) { "http://#{file_server_address}/unstaged/node_with_procfile" }
  let(:staged_url) { "http://#{file_server_address}/staged/node_with_procfile" }
  let(:properties) { {} }

  let(:start_message) do
    {
      "index" => 1,
      "droplet" => "some-app-id",
      "version" => "some-version",
      "name" => "some-app-name",
      "uris" => [],
      "prod" => false,
      "sha1" => nil,
      "executableUri" => nil,
      "cc_partition" => "foo",
      "limits" => {
        "mem" => 64,
        "disk" => 128,
        "fds" => 32
      },
      "services" => []
    }
  end

  let(:staging_message) do
    {
      "app_id" => "some-node-app-id",
      "properties" => properties,
      "task_id" => "task-id",
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => "http://#{file_server_address}/buildpack_cache",
      "buildpack_cache_download_uri" => "http://#{file_server_address}/buildpack_cache",
      "start_message" => start_message
    }
  end

  it "downloads node from Heroku's S3 mirror of nodejs.org/dist and stages the app properly" do
    response, log = perform_stage_request(staging_message)

    expect(response["error"]).to be_nil
    expect(response["detected_buildpack"]).to eq("Node.js")

    output_from_compile = "Downloading and installing node"
    expect(log).to include(output_from_compile)

    download_tgz(staged_url) do |dir|
      expect(File.readlines("#{dir}/app/vendor/node/ChangeLog").first.strip).to eq("2013.03.21, Version 0.10.1 (Stable)")
    end
  end

  context "when dependencies have incompatible versions" do
    let(:unstaged_url) { "http://#{file_server_address}/unstaged/node_with_incompatibility" }
    let(:staged_url) { "http://#{file_server_address}/staged/node_with_incompatibility" }

    it "fails to stage" do
      response, log = perform_stage_request(staging_message)

      expect(response["error"]).to include "Script exited with status 1"

      # Bcrypt 0.4.1 is incompatible with node 0.10, using node-waf and node-gyp respectively
      expect(log).to include("make: node-waf: Command not found")
      expect(log).to_not include("Building runtime environment")
    end
  end

  describe "Running node.js buildpack tests" do
    let(:unstaged_url) { "http://#{file_server_address}/unstaged/node_buildpack_tests" }
    let(:properties) do
      {
          "buildpack" => "git://github.com/ddollar/buildpack-test.git",
          "meta" => { "command" => "echo 'Starting nothing'"}
      }
    end

    it "passes (for the most part, but fails intermittently)" do
      # There appears to be an existing problem with Heroku's tests for this buildpack
      # where different tests will fail intermittently. We've seen these pass several times
      # in a row now and are avoiding making changes to the buildpack so we're going to live
      # with this for now.

      _, log = perform_stage_request(staging_message)

      expect(log).to include "Running bin/test"
      expect(log).to include "OK"
    end
  end
end
