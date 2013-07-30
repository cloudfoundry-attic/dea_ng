require "spec_helper"

describe "Running a Java App", :type => :integration, :requires_warden => true do
  let(:nats) { NatsHelper.new }

  let(:app_id) { SecureRandom.hex(8) }
  let(:unstaged_url) { "http://localhost:9999/unstaged/java_with_oome" }
  let(:staged_url) { "http://localhost:9999/staged/java_with_oome" }
  let(:buildpack_cache_download_uri) { "http://localhost:9999/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://localhost:9999/buildpack_cache" }
  let(:original_memory) do
    dea_config["resources"]["memory_mb"] * dea_config["resources"]["memory_overcommit_factor"]
  end

  let(:dea_stage_msg) do
    {
      "app_id" => app_id,
      "properties" => {},
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => "http://localhost:9999/buildpack_cache",
      "buildpack_cache_download_uri" => "http://localhost:9999/buildpack_cache"
    }
  end

  let(:dea_start_msg) do
    {
      "index" => 1,
      "droplet" => app_id,
      "version" => "some-version",
      "name" => "oome",
      "uris" => [],
      "sha1" => sha1_url(staged_url),
      "executableUri" => staged_url,
      "cc_partition" => "foo",
      "limits" => {
        "mem" => 256,
        "disk" => 1024,
        "fds" => 999
      },
      "services" => []
    }
  end

  let(:dea_stop_msg) { {"droplet" => app_id} }

  context "when the app has an out of memory exception" do
    it "it starts the app normally then after getting an out of memory exception crashes warden" do
      pending "wait until the java buildpack team has pushed the new buildpack and verify that this passes."

      by "staging the app" do
        nats.make_blocking_request("staging", dea_stage_msg, 2)
        nats.publish("dea.#{dea_id}.start", dea_start_msg.merge("env" => ["crash=false"]))
        wait_until_instance_started(app_id, 90)
      end

      by "restart the app" do
        nats.publish("dea.stop", dea_stop_msg)
        wait_until_instance_gone(app_id, 91) # 91 because it shows up better in the logs

        nats.publish("dea.#{dea_id}.start", dea_start_msg.merge("env" => ["crash=true"]))
        wait_until_instance_gone(app_id, 90)
      end
    end
  end
end
