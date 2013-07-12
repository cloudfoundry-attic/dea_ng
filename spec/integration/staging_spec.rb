require "spec_helper"
require "spec_helper"
require "net/http"
require "uri"

describe "Staging an app", :type => :integration, :requires_warden => true do
  FILE_SERVER_DIR = "/tmp/dea"

  let(:nats) { NatsHelper.new }
  let(:unstaged_url) { "http://localhost:9999/unstaged/sinatra" }
  let(:staged_url) { "http://localhost:9999/staged/sinatra" }
  let(:buildpack_cache_download_uri) { "http://localhost:9999/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://localhost:9999/buildpack_cache" }
  let(:app_id) { "some-app-id" }
  let(:properties) { {} }
  let(:start_staging_message) do
    {
      "async" => true,
      "app_id" => app_id,
      "task_id" => "foobar",
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
      responses = nats.make_blocking_request("staging", start_staging_message, 2)

      expect(responses[1]["error"]).to be_nil
      log = responses[1]["task_log"]
      expect(log).to include("-----> Downloaded app package")
      expect(log).to include("-----> Uploading droplet")
    end


    it "uploads buildpack cache after staging" do
      buildpack_cache_file = File.join(FILE_SERVER_DIR, "buildpack_cache.tgz")
      FileUtils.rm_rf(buildpack_cache_file)
      nats.make_blocking_request("staging", start_staging_message, 2)
      expect(File.exist?(buildpack_cache_file)).to be_true
    end

    it "downloads buildpack cache before staging" do
      nats.make_blocking_request("staging", start_staging_message, 2)
      Dir.mktmpdir do |tmp|
        Dir.chdir(tmp) do
          `curl -s #{staged_url} | tar xfz -`
          expect(File.exist?(File.join("app", "cached_file"))).to be_true
        end
      end
    end

    it "cleans buildpack cache between staging" do
      nats.make_blocking_request("staging", start_staging_message, 2)
      Dir.mktmpdir do |tmp|
        Dir.chdir(tmp) do
          buildpack_cache_file = File.join(FILE_SERVER_DIR, "buildpack_cache.tgz")
          `tar -zxvf #{buildpack_cache_file}`
          expect(File.exist?("new_cached_file")).to be_true
          expect(File.exist?("cached_file")).to_not be_true
        end
      end
    end
  end

  context "when environment variable was specified in staging request" do
    let(:buildpack_url) do
      setup_fake_buildpack("start_command")
      fake_buildpack_url("start_command")
    end
    let(:properties) do
      {
        "buildpack" => buildpack_url,
        "environment" => ["FOO=BAR","BLAH=WHATEVER"]
      }
    end

    it "has access to application environment variables" do
      responses = nats.make_blocking_request("staging", start_staging_message, 2)
      expect(responses[1]["task_log"]).to include("-----> Running foo based script\n")
    end
  end

  context "while staging is running" do
    let(:properties) do
      setup_fake_buildpack("start_command")
      {"buildpack" => fake_buildpack_url("start_command")}
    end

    it "decreases the DEA's available memory (could be fickle)" do
      initial_mem = dea_memory
      available_memory_while_staging = nil
      nats.make_blocking_request("staging", start_staging_message, 2) do |index, _|
        if index == 0
          NATS.publish("dea.locate", Yajl::Encoder.encode({}))
          NATS.subscribe("dea.advertise") do |resp|
            available_memory_while_staging = Yajl::Parser.parse(resp)["available_memory"]
          end
        end
      end
      expect(available_memory_while_staging).to equal(initial_mem - 1024)
    end

    it "streams the logs back to the user" do
      first_line_streamed = nil

      nats.make_blocking_request("staging", start_staging_message, 2) do |index, response|
        if index == 0
          uri = URI.parse(response["task_streaming_log_url"])
          uri.host = "127.0.0.1"
          uri.port = 5678

          first_line_streamed = Net::HTTP.get(uri)
        end
      end

      expect(first_line_streamed).to include("Downloaded app package")
    end
  end

  context "when an invalid upload URI is given" do
    let(:staged_url) { "http://localhost:45459/not_real" }
    let(:properties) do
      setup_fake_buildpack("start_command")
      {"buildpack" => fake_buildpack_url("start_command")}
    end

    it "does not crash" do
      responses = nats.make_blocking_request("staging", start_staging_message, 2)
      expect(responses[1]["error"]).to include("Error uploading")
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

      context "when staging is in process" do
        it "stops staging tasks" do
          responses = nats.make_blocking_request("staging", start_staging_message, 2) do
            Process.kill("USR2", dea_pid)
          end

          expect(responses[1]["error"]).to eq("Error staging: task stopped")
          expect(responses[1]["task_id"]).to eq(responses[0]["task_id"])
        end
      end
    end

    context "when stop request is published" do
      it "stops staging task" do
        responses = nats.make_blocking_request("staging", start_staging_message, 2) do
          NATS.publish("staging.stop", Yajl::Encoder.encode({"app_id" => app_id}))
        end

        expect(responses[1]["error"]).to eq("Error staging: task stopped")
      end
    end
  end
end
