require "spec_helper"
require "net/http"

describe "Staging an app", :type => :integration, :requires_warden => true do
  FILE_SERVER_DIR = "/tmp/dea"

  let(:nats) { NatsHelper.new }
  let(:unstaged_url) { "http://localhost:9999/unstaged/sinatra" }
  let(:staged_url) { "http://localhost:9999/staged/sinatra" }
  let(:buildpack_cache_download_uri) { "http://localhost:9999/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://localhost:9999/buildpack_cache" }
  let(:async_staging) { false }
  let(:app_id) { "some-app-id" }
  let(:properties) { {} }
  let(:start_staging_message) do
    {
      "async" => async_staging,
      "app_id" => app_id,
      "properties" => properties,
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
      "buildpack_cache_download_uri" => buildpack_cache_download_uri
    }
  end

  context "when a buildpack url is specified" do
    let(:buildpack_url) do
      setup_fake_buildpack("start_command")
      fake_buildpack_url("start_command")
    end
    let(:properties) { {"buildpack" => buildpack_url} }


    it "downloads the buildpack and runs it" do
      response = nats.request("staging", start_staging_message)

      expect(response["error"]).to be_nil
      response["task_log"].tap do |log|
        expect(log).to include("-----> Downloaded app package (4.0K)\n")
        expect(log).to include("-----> Some compilation output\n")
        expect(log).to include("-----> Uploading staged droplet (4.0K)\n")
        expect(log).to include("-----> Uploaded droplet\n")
      end
    end

    it "uploads buildpack cache after staging" do
      buildpack_cache_file = File.join(FILE_SERVER_DIR, "buildpack_cache.tgz")
      FileUtils.rm_rf(buildpack_cache_file)
      nats.request("staging", start_staging_message)
      expect(File.exist?(buildpack_cache_file)).to be_true
    end

    it "downloads buildpack cache before staging" do
      nats.request("staging", start_staging_message)
      Dir.mktmpdir do |tmp|
        Dir.chdir(tmp) do
          `curl -s #{staged_url} | tar xfz -`
          expect(File.exist?(File.join("app", "cached_file"))).to be_true
        end
      end
    end
  end

  context "when staging is running" do
    let(:async_staging) { true }
    let(:properties) do
      setup_fake_buildpack("start_command")
      {"buildpack" => fake_buildpack_url("start_command")}
    end

    it "decreases the DEA's available memory" do
      expect {
        nats.request("staging", start_staging_message)
      }.to change { dea_memory }.by(-1024)

      # TODO: explore better approach
      # This test require async staging, wait for it to finish
      sleep 2
    end
  end

  context "when a invalid upload URI is given" do
    let(:staged_url) { "http://localhost:45459/not_real" }
    let(:properties) do
      setup_fake_buildpack("start_command")
      {"buildpack" => fake_buildpack_url("start_command")}
    end

    it "does not crash" do
      response = nats.request("staging", start_staging_message)
      expect(response["error"]).to include("Error uploading")
      expect(dea_memory).to be > 0
    end
  end

  describe "running staging tasks" do
    let(:buildpack_url) do
      setup_fake_buildpack("long_compiling_buildpack")
      fake_buildpack_url("long_compiling_buildpack")
    end
    let(:properties) { {"buildpack" => buildpack_url} }

    context "when the shutdown started" do
      after { dea_start }

      context "when asynchronous staging is in process" do
        let(:async_staging) { true }
        it "stops staging tasks" do
          message = Yajl::Encoder.encode(start_staging_message)
          task_id = nil

          first_response = lambda do |response|
            task_id = response["task_id"]
            Process.kill("USR2", dea_pid)
          end

          second_response = lambda do |response|
            expect(response["error"]).to eq("Error staging: task stopped")
            expect(response["task_id"]).to eq(task_id)
          end

          nats.with_async_staging message, first_response, second_response
        end
      end

      context "when synchronous staging is in process" do
        it "stops staging tasks" do
          NATS.start do
            message = Yajl::Encoder.encode(start_staging_message)
            sid = NATS.request("staging", message) do |response|
              response = Yajl::Parser.parse(response)
              expect(response["error"]).to eq("Error staging: task stopped")
              NATS.stop
            end
            sleep 2
            Process.kill("USR2", dea_pid)
            NATS.timeout(sid, 10) { raise "Staging task did not stopped within timeout" }
          end
        end
      end
    end

    context "when stop request is published" do
      let(:async_staging) { true }

      it "stops staging task" do
        message = Yajl::Encoder.encode(start_staging_message)

        first_response = lambda do |_|
          NATS.publish("staging.stop", Yajl::Encoder.encode({"app_id" => app_id}))
        end

        second_response = lambda do |response|
          expect(response["error"]).to eq("Error staging: task stopped")
        end

        nats.with_async_staging message, first_response, second_response
      end
    end
  end
end
