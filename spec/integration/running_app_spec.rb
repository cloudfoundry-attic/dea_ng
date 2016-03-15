require "spec_helper"
require "securerandom"

describe "Running an app", :type => :integration, :requires_warden => true do
  let(:unstaged_url) { "http://#{file_server_address}/unstaged/sinatra" }
  let(:staged_url) { "http://#{file_server_address}/staged/sinatra" }
  let(:buildpack_cache_download_uri) { "http://#{file_server_address}/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://#{file_server_address}/buildpack_cache" }
  let(:app_id) { SecureRandom.hex(8) }

  let(:valid_provided_service) do
    {
      "credentials" => { "user" => "Jerry", "password" => "Jellison" },
      "options" => {},
      "label" => "Unmanaged Service abcdefg",
      "name" => "monacle"
    }
  end

  def start_message
    {
      "index" => 1,
      "droplet" => app_id,
      "version" => "some-version",
      "name" => "some-app-name",
      "uris" => [],
      "sha1" => sha1_url(staged_url),
      "executableUri" => staged_url,
      "cc_partition" => "foo",
      "limits" => {
        "mem" => 64,
        "disk" => 128,
        "fds" => 32
      },
      "services" => [valid_provided_service],
      "stack" => "cflinuxfs2",
    }
  end

  let(:staging_message) do
    {
      "app_id" => app_id,
      "properties" => { "buildpack" => fake_buildpack_url("start_command"), },
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
      "buildpack_cache_download_uri" => buildpack_cache_download_uri,
      "start_message" => start_message,
      "stack" => "cflinuxfs2",
    }
  end

  def stage
    stager_id = get_stager_id
    nats.make_blocking_request("staging.#{stager_id}.start", staging_message, 2)
  end

  def stop
    nats.publish("dea.stop", {"droplet" => app_id})
  end

  def wait_until_started
    wait_until_instance_started(app_id)
  end

  def wait_until_stopped
    wait_until_instance_gone(app_id)
  end

  describe "setting up an invalid application" do
    let(:start_message) do
      {
        "index" => 1,
        "droplet" => app_id,
        "version" => "some-version",
        "name" => "some-app-name",
        "uris" => "invalid-uri",
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

    it "does not allocate any memory" do
      setup_fake_buildpack("start_command")

      expect do
        stage

        begin
          wait_until do
            nats.request("dea.find.droplet", {
              "droplet" => app_id,
            }, :timeout => 1)
          end

          fail("App was created and should not have been")
        rescue Timeout::Error
        end
      end.to_not change { dea_memory }
    end
  end

  describe 'starting a valid application' do
    before do
      setup_fake_buildpack("start_command")
    end

    after do
      nats.publish("dea.stop", {"droplet" => app_id})
      wait_until_instance_gone(app_id)
    end

    describe "starting the app" do
      it "decreases the dea's available memory" do
        expect {
          stage
          wait_until_started
        }.to change { dea_memory }.by(-64)
      end
    end

    describe 'retrieving droplet stats with dea.find.droplet' do
      it 'returns stats in the nats response' do
        stage
        wait_until_started

        droplet_message = Yajl::Encoder.encode("droplet" => app_id, "states" => ["RUNNING"], 'include_stats' => true)
        nats.with_nats do
          NATS.subscribe("router.register") do |_|
            NATS.request("dea.find.droplet", droplet_message, :timeout => 5) do |response|
              droplet_info = Yajl::Parser.parse(response)
              ustats = droplet_info['stats']['usage']
              expect(ustats).to include('cpu', 'mem')
              expect(ustats['disk']).to eq(65536)
              NATS.stop
            end
          end
        end
      end
    end

    describe "stopping the app" do
      it "restores the dea's available memory" do
        stage
        wait_until_started

        expect {
          stop
          wait_until_stopped
        }.to change { dea_memory }.by(64)
      end

      it "actually stops the app" do
        stage
        wait_until_started

        checked_port = false
        droplet_message = Yajl::Encoder.encode("droplet" => app_id, "states" => ["RUNNING"])

        nats.with_nats do
          NATS.subscribe("router.register") do |_|
            NATS.request("dea.find.droplet", droplet_message, :timeout => 5) do |response|
              droplet_info = Yajl::Parser.parse(response)
              instance_info = instance_snapshot(droplet_info["instance"])

              port = instance_info["instance_host_port"]
              expect(is_port_open?(dea_host, port)).to eq(true)

              NATS.publish("dea.stop", Yajl::Encoder.encode({"droplet" => app_id})) do
                port_open = true
                wait_until(10) do
                  port_open = is_port_open?(dea_host, port)
                  !port_open
                end

                expect(port_open).to eq(false)
                checked_port = true
                NATS.stop
              end
            end
          end
        end

        expect(checked_port).to eq(true)
      end

      it "receives logs during graceful shutdown" do
        setup_fake_buildpack("graceful_shutdown")
        staging_message["properties"]["buildpack"] = fake_buildpack_url("graceful_shutdown")
        stage
        wait_until_started

        logs = ""
        finished = false
        logging_thread = nil
        droplet_message = Yajl::Encoder.encode("droplet" => app_id, "states" => ["RUNNING"])

        nats.with_nats do
          NATS.subscribe("router.register") do |_|
            NATS.request("dea.find.droplet", droplet_message, :timeout => 5) do |response|
              droplet_info = Yajl::Parser.parse(response)
              instance_info = instance_snapshot(droplet_info["instance"])
              port = instance_info["instance_host_port"]

              app_socket_path = File.join(instance_info["warden_container_path"], "jobs", instance_info["warden_job_id"].to_s, "stdout.sock")
              log_socket = UNIXSocket.open(app_socket_path)

              logging_thread = Thread.new do
                while line = log_socket.gets
                  logs << line
                end
              end

              NATS.publish("dea.stop", Yajl::Encoder.encode({"droplet" => app_id})) do
                wait_until(10) { !is_port_open?(dea_host, port) }

                finished = true
                NATS.stop
              end
            end
          end
        end

        logging_thread.join
        expect(finished).to eq(true)
        expect(logs).to include("Trapped TERM signal")
      end
    end
  end
end
