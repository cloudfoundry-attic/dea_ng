require "spec_helper"
require "securerandom"

describe "Running an app", :type => :integration, :requires_warden => true do
  let(:nats) { NatsHelper.new }
  let(:unstaged_url) { "http://localhost:9999/unstaged/sinatra" }
  let(:staged_url) { "http://localhost:9999/staged/sinatra" }
  let(:buildpack_cache_download_uri) { "http://localhost:9999/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://localhost:9999/buildpack_cache" }
  let(:app_id) { SecureRandom.hex(8) }
  let(:original_memory) do
    dea_config["resources"]["memory_mb"] * dea_config["resources"]["memory_overcommit_factor"]
  end
  let(:valid_dea_start_message) {
    {
      "index" => 1,
      "droplet" => app_id,
      "version" => "some-version",
      "name" => "some-app-name",
      "uris" => [],
      "prod" => false,
      "sha1" => sha1_url(staged_url),
      "executableUri" => staged_url,
      "cc_partition" => "foo",
      "limits" => {
        "mem" => 64,
        "disk" => 128,
        "fds" => 32
      },
      "services" => []
    }
  }

  describe 'setting up an invalid application' do
    it 'does not allocate any memory' do
      setup_fake_buildpack("start_command")

      nats.request("staging", {
        "async" => false,
        "app_id" => "A string not an integer ",
        "properties" => {
          "buildpack" => fake_buildpack_url("start_command"),
        },
        "download_uri" => unstaged_url,
        "upload_uri" => staged_url,
        "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
        "buildpack_cache_download_uri" => buildpack_cache_download_uri
      })


      nats.publish("dea.#{dea_id}.start", valid_dea_start_message.merge(uris: "this is an invalid application uri"))

      begin
        wait_until do
          nats.request("dea.find.droplet", {
            "droplet" => app_id,
          }, :timeout => 1)
        end

        fail("App was created and should not have been")
      rescue Timeout::Error
        expect(dea_memory).to eql(original_memory)
      end
    end
  end

  describe 'starting a valid application' do
    before do
      setup_fake_buildpack("start_command")

      nats.request("staging", {
        "async" => false,
        "app_id" => app_id,
        "properties" => {
          "buildpack" => fake_buildpack_url("start_command"),
        },
        "download_uri" => unstaged_url,
        "upload_uri" => staged_url,
        "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
        "buildpack_cache_download_uri" => buildpack_cache_download_uri
      })
    end

    after do
      nats.publish("dea.stop", {"droplet" => app_id})
      wait_until_instance_gone(app_id)
    end

    describe "starting the app" do
      before do
        nats.publish("dea.#{dea_id}.start", valid_dea_start_message)
        wait_until_instance_started(app_id)
      end

      it "decreases the dea's available memory" do
        expect(dea_memory).to eql(original_memory - 64)
      end
    end

    describe "stopping the app" do
      it "restores the dea's available memory" do
        nats.publish("dea.#{dea_id}.start", valid_dea_start_message)
        wait_until_instance_started(app_id)

        nats.publish("dea.stop", {"droplet" => app_id})
        wait_until_instance_gone(app_id)
        expect(dea_memory).to eql(original_memory)
      end

      it "actually stops the app" do
        id = dea_id
        checked_port = false
        droplet_message = Yajl::Encoder.encode({"droplet" => app_id, "states" => ["RUNNING"]})
        NATS.start do
          NATS.subscribe("router.register") do |_|
            NATS.request("dea.find.droplet", droplet_message, :timeout => 5) do |response|
              droplet_info = Yajl::Parser.parse(response)
              instance_info = instance_snapshot(droplet_info["instance"])
              ip = instance_info["warden_host_ip"]
              port = instance_info["instance_host_port"]
              expect(is_port_open?(ip, port)).to eq(true)

              NATS.publish("dea.stop", Yajl::Encoder.encode({"droplet" => app_id})) do
                port_open = true
                wait_until do
                  port_open = is_port_open?(ip, port)
                  ! port_open
                end
                expect(port_open).to eq(false)
                checked_port = true
                NATS.stop
              end
            end
          end

          NATS.publish("dea.#{id}.start", Yajl::Encoder.encode(valid_dea_start_message))
        end

        expect(checked_port).to eq(true)
      end
    end
  end
end
