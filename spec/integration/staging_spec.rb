require "spec_helper"
require "net/http"
require "uri"
require "vcap/common"
require "securerandom"

describe "Staging an app", :type => :integration, :requires_warden => true do
  let(:unstaged_url) { "http://#{file_server_address}/unstaged/sinatra" }
  let(:staged_url) { "http://#{file_server_address}/staged/sinatra" }
  let(:buildpack_cache_download_uri) { "http://#{file_server_address}/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://#{file_server_address}/buildpack_cache" }
  let(:app_id) { "some-app-id" }
  let(:properties) { {} }
  let(:task_id) { SecureRandom.uuid }
  let(:env) { ["FOO=bar baz","BLAH=WHATEVER"] }
  let(:memory_limit) { 64 }
  let(:limits) do
    {
      "mem" => memory_limit,
      "disk" => 128,
      "fds" => 32
    }
  end

  let(:start_message) do
    {
      "index" => 1,
      "droplet" => app_id,
      "version" => "some-version",
      "name" => "some-app-name",
      "uris" => [],
      "prod" => false,
      "sha1" => nil,
      "executableUri" => nil,
      "cc_partition" => "foo",
      "limits" => limits,
      "services" => [],
      "env" => env
    }
  end

  let(:staging_message) do
    {
      "app_id" => app_id,
      "task_id" => task_id,
      "properties" => properties,
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
      "buildpack_cache_download_uri" => buildpack_cache_download_uri,
      "start_message" => start_message
    }
  end

  context "when a buildpack url is specified" do
    let(:buildpack_url) do
      setup_fake_buildpack("start_command")
      fake_buildpack_url("start_command")
    end

    let(:properties) { {"buildpack" => buildpack_url, "environment" => env, "resources" => limits} }

    it "works" do
      buildpack_cache_file = File.join(FILE_SERVER_DIR, "buildpack_cache.tgz")
      FileUtils.rm_rf(buildpack_cache_file)

      response, staging_log = perform_stage_request(staging_message)

      by "downloading the buildpack and running it" do
        expect(response["error"]).to be_nil
        expect(staging_log).to include("-----> Downloaded app package")
        expect(staging_log).to include("-----> Uploading droplet")
      end

      and_by "uploading buildpack cache after staging" do
        expect(File.exist?(buildpack_cache_file)).to be_true
      end

      and_by "downloading buildpack cache before staging" do
        Dir.mktmpdir do |tmp|
          Dir.chdir(tmp) do
            `curl -s #{staged_url} | tar xfz -`
            expect(File.exist?(File.join("app", "cached_file"))).to be_true
          end
        end
      end

      and_by "cleaning the buildpack cache between staging" do
        Dir.mktmpdir do |tmp|
          Dir.chdir(tmp) do
            buildpack_cache_file = File.join(FILE_SERVER_DIR, "buildpack_cache.tgz")
            `tar -zxf #{buildpack_cache_file}`
            expect(File.exist?("new_cached_file")).to be_true
            expect(File.exist?("cached_file")).to_not be_true
          end
        end
      end

      and_by "setting the correct user environment variables" do
        expect(staging_log).to include("FOO=bar baz")
        expect(staging_log).to include("BLAH=WHATEVER")
      end

      and_by "setting the correct system environment variables" do
        expect(staging_log).to include("VCAP_APPLICATION=")
        expect(staging_log).to include("MEMORY_LIMIT=#{memory_limit}m")
      end
    end
  end

  context "while staging is running" do
    let(:properties) do
      setup_fake_buildpack("start_command")
      {"buildpack" => fake_buildpack_url("start_command")}
    end

    it "streams the logs back to the user" do
      _, log = perform_stage_request(staging_message)
      expect(log).to include("Downloaded app package")
    end
  end

  context "when an invalid upload URI is given" do
    let(:staged_url) { "http://localhost:45459/not_real" }
    let(:properties) do
      setup_fake_buildpack("start_command")
      {"buildpack" => fake_buildpack_url("start_command")}
    end

    it "does not crash" do
      response, _ = perform_stage_request(staging_message)
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

    it "decreases the DEA's available memory" do
      initial_mem = dea_memory

      available_memory_while_staging = nil
      expected_responses = 2

      nats.make_blocking_request("staging", staging_message, expected_responses, 20) do |index, _|
        if index == 0
          NATS.publish("dea.locate", Yajl::Encoder.encode({})) do
            NATS.subscribe("dea.advertise") do |resp|
              available_memory_while_staging = Yajl::Parser.parse(resp)["available_memory"]
            end

            NATS.publish("staging.stop", Yajl::Encoder.encode({"app_id" => app_id}))
          end
        end
      end

      expect(available_memory_while_staging).to equal(initial_mem - 1024)
    end

    context "when the shutdown started" do
      after { dea_start }

      context "when staging is in process" do
        it "stops staging tasks" do
          responses = nats.make_blocking_request("staging", staging_message, 2) do |response_index, _|
            evacuate_dea if response_index == 0
          end

          # We either get response from failed staging or stop request
          expect(responses[1]["error"]).to match /Error staging: task stopped|Script exited with status 255/
          expect(responses[1]["task_id"]).to eq(responses[0]["task_id"])
        end
      end
    end

    context "when stop request is published" do
      let(:start_message) { nil }

      it "stops staging task" do
        responses = nats.make_blocking_request("staging", staging_message, 2) do |response_index, _|
          if response_index == 0
            NATS.publish("staging.stop", Yajl::Encoder.encode("app_id" => app_id))
          end
        end

        expect(responses[1]["error"]).to eq("Error staging: task stopped")
      end
    end
  end
end
