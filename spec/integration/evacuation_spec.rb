require "spec_helper"

describe "Deterministic Evacuation", :type => :integration, :requires_warden => true do
  let(:unstaged_url) { "http://#{file_server_address}/unstaged/sinatra" }
  let(:staged_url) { "http://#{file_server_address}/staged/sinatra" }
  let(:buildpack_cache_download_uri) { "http://#{file_server_address}/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://#{file_server_address}/buildpack_cache" }
  let(:app_id) { SecureRandom.hex(8) }

  let(:valid_provided_service) do
    {
      "credentials" => {"user" => "Jerry", "password" => "Jellison"},
      "options" => {},
      "label" => "Unmanaged Service abcdefg",
      "name" => "monacle"
    }
  end

  let(:start_message) do
    {
      "index" => 1,
      "droplet" => app_id,
      "version" => "some-version",
      "name" => "some-app-name",
      "uris" => ["abc.example.com"],
      "sha1" => sha1_url(staged_url),
      "executableUri" => staged_url,
      "cc_partition" => "foo",
      "limits" => {
        "mem" => 64,
        "disk" => 128,
        "fds" => 32
      },
      "services" => [valid_provided_service]
    }
  end

  let(:staging_message) do
    {
      "app_id" => app_id,
      "properties" => {"buildpack" => fake_buildpack_url("start_command"), },
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
      "buildpack_cache_download_uri" => buildpack_cache_download_uri,
      "start_message" => start_message
    }
  end

  def ensure_instance_registers_with_router(app_id)
    wait_until do
      success = false
      nats.with_nats do
        NATS.subscribe('router.register') do |resp|
          registration = Yajl::Parser.parse(resp)
          if registration["app"]
            expect(registration["app"]).to eq(app_id)
            success = true
            NATS.stop
          end
        end
      end
      success == true
    end
  end

  it "starts heartbeating in the EVACUATING state and, when all EVACUATING instances are stopped, it dies" do
    expect(dea_server).to_not be_terminated

    setup_fake_buildpack("start_command")
    nats.make_blocking_request("staging", staging_message, 2)

    wait_until_instance_started(app_id)

    dea_server.evacuate

    wait_until_instance_evacuating(app_id)

    ensure_instance_registers_with_router(app_id)

    nats.publish("dea.stop", {"droplet" => app_id})
    wait_until_instance_gone(app_id)

    dea_server.evacuate

    wait_until(5) do
      dea_server.terminated?
    end
  end
end
