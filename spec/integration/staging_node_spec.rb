require "spec_helper"
require "net/http"

describe "Staging a node app", :type => :integration, :requires_warden => true do
  let(:nats) { NatsHelper.new }
  let(:unstaged_url) { "http://localhost:9999/unstaged/node_with_procfile" }
  let(:staged_url) { "http://localhost:9999/staged/node_with_procfile" }
  let(:start_staging_message) do
    {
        "async" => false,
        "app_id" => "some-node-app-id",
        "properties" => {},
        "download_uri" => unstaged_url,
        "upload_uri" => staged_url,
        "buildpack_cache_upload_uri" => "http://localhost:9999/buildpack_cache",
        "buildpack_cache_download_uri" => "http://localhost:9999/buildpack_cache"
    }
  end

  it "packages up the node dependencies and stages the app properly" do
    response = nats.request("staging", start_staging_message)

    expect(response["detected_buildpack"]).to eq("Node.js")
    expect(response["task_log"]).to include("Resolving engine versions")
    expect(response["task_log"]).to include("Fetching Node.js binaries")
    expect(response["task_log"]).to include("Vendoring node into slug")
    expect(response["task_log"]).to include("Installing dependencies with npm")
    expect(response["task_log"]).to include("Building runtime environment")
    expect(response["error"]).to be_nil

    download_tgz(staged_url) do |dir|
      entries = Dir.entries(dir).join(" ")
      expect(entries).to match(/nodejs-0\.10\.\d+\.tgz/)
      expect(entries).to match(/scons-1\.2\.\d+\.tgz/)
      expect(entries).to match(/npm-1\.2.\d+\.tgz/)
      expect(entries).to match(/nodejs-0\.4\.\d+\.tgz/)
    end
  end

  context "when dependencies have incompatible versions" do
    let(:unstaged_url) { "http://localhost:9999/unstaged/node_with_incompatibility" }
    let(:staged_url) { "http://localhost:9999/staged/node_with_incompatibility" }

    it "fails to stage" do
      response = nats.request("staging", start_staging_message)

      expect(response["error"]).to include "Script exited with status 1"
      # Bcrypt 0.4.1 is incompatible with node 0.10, using node-waf and node-gyp respectively
      expect(response["task_log"]).to include("make: node-waf: Command not found")
      expect(response["task_log"]).to_not include("Building runtime environment")
    end
  end
end