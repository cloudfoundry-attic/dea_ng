require "spec_helper"

describe "Running an app immediately after staging", :type => :integration, :requires_warden => true do
  let(:unstaged_url) { "http://#{file_server_address}/unstaged/sinatra" }
  let(:staged_url) { "http://#{file_server_address}/staged/sinatra" }
  let(:buildpack_cache_download_uri) { "http://#{file_server_address}/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://#{file_server_address}/buildpack_cache" }
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
        "mem" => 1024,
        "disk" => 128,
        "fds" => 32
      },
      "services" => [],
      "egress_network_rules" => [],
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
      "egress_network_rules" => [],
      "start_message" => start_message,
    }
  end

  let(:uploaded_droplet) { File.join(FILE_SERVER_DIR, "sinatra") }

  before do
    FileUtils.rm_rf(uploaded_droplet)
  end

  it "works" do
    by "staging the app" do
      response, log = perform_stage_request(staging_running_message)

      expect(response["task_id"]).to eq("some-task-id")
      expect(response["error"]).to be_nil

      expect(log).to include("-----> Downloaded app package")
      expect(log).to include("-----> Uploading droplet")
    end

    and_by "starting the app" do
      response = wait_until_instance_started(app_id)
      instance_info = instance_snapshot(response["instance"])
      port = instance_info["instance_host_port"]
      expect(is_port_open?(dea_host, port)).to eq(true)
    end

    and_by "uploading the droplet" do
      expect(File.exist?(uploaded_droplet)).to be_true
    end
  end
end
