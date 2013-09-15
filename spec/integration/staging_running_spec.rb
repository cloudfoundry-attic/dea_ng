require "spec_helper"

describe "Running an app", :type => :integration, :requires_warden => true do
  let(:unstaged_url) { "http://#{FILE_SERVER_ADDRESS}/unstaged/sinatra" }
  let(:staged_url) { "http://#{FILE_SERVER_ADDRESS}/staged/sinatra" }
  let(:buildpack_cache_download_uri) { "http://#{FILE_SERVER_ADDRESS}/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://#{FILE_SERVER_ADDRESS}/buildpack_cache" }
  let(:buildpack_url) do
    setup_fake_buildpack("start_command")
    fake_buildpack_url("start_command")
  end

  let(:app_id) { "some-app-id" }

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

  let(:staging_running_message) do
    {
      "app_id" => app_id,
      "task_id" => "some-task-id",
      "properties" => {"buildpack" => buildpack_url},
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
      "buildpack_cache_download_uri" => buildpack_cache_download_uri,
      "start_message" => start_message
    }
  end

  let(:uploaded_droplet) { File.join(FILE_SERVER_DIR, "sinatra") }

  before do
    FileUtils.rm_rf(uploaded_droplet)
  end

  it "works" do
    responses = nats.make_blocking_request("staging", staging_running_message, 2)

    by "starts the staging" do
      expect(responses[0]["task_id"]).to eq("some-task-id")
      expect(responses[0]["task_streaming_log_url"]).to match /^http/
    end

    and_by "sends the correct staging finished message back to CC" do
      expect(responses[1]["task_id"]).to eq("some-task-id")
      expect(responses[1]["error"]).to be_nil
      expect(responses[1]["task_log"]).to include("-----> Downloaded app package")
      expect(responses[1]["task_log"]).to include("-----> Uploading droplet")
    end

    and_by "starts the app" do
      response = wait_until_instance_started(app_id)
      instance_info = instance_snapshot(response["instance"])
      port = instance_info["instance_host_port"]
      expect(is_port_open?(dea_host, port)).to eq(true)
    end

    and_by "uploads the droplet" do
      expect(File.exist?(uploaded_droplet)).to be_true
    end
  end
end
