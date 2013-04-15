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
  let(:start_staging_message) do
    {
      "async" => async_staging,
      "app_id" => app_id,
      "properties" => {},
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
      "buildpack_cache_download_uri" => buildpack_cache_download_uri
    }
  end

  describe "staging a simple nodejs app" do
    let(:unstaged_url) { "http://localhost:9999/unstaged/app_with_procfile" }
    let(:staged_url) { "http://localhost:9999/staged/app_with_procfile" }
    let(:app_id) { "some-node-app-id" }

    it "packages up the node dependencies and stages the app properly" do
      response = nats.request("staging", start_staging_message)

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

  describe "staging a simple sinatra app" do
    context "when the DEA has to detect the buildback" do
      let(:start_staging_message) {
        {
          "async" => false,
          "app_id" => "some-app-id",
          "properties" => {},
          "download_uri" => unstaged_url,
          "upload_uri" => staged_url,
          "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
          "buildpack_cache_download_uri" => buildpack_cache_download_uri
        }
      }
      it "packages a ruby binary and the app's gems" do
        response = nats.request("staging", start_staging_message)

        response["task_log"].should include("Your bundle is complete!")
        response["error"].should be_nil

        download_tgz(staged_url) do |dir|
          Dir.entries("#{dir}/app/vendor").should include("ruby-1.9.2")
          Dir.entries("#{dir}/app/vendor/bundle/ruby/1.9.1/gems").should =~ %w[
            .
            ..
            bundler-1.3.2
            rack-1.5.1
            rack-protection-1.3.2
            sinatra-1.3.4
            tilt-1.3.3
          ]
        end
      end

      it "reports back detected buildpack" do
        response = nats.request("staging", start_staging_message)

        response["detected_buildpack"].should eq("Ruby/Rack")
      end
    end

    context "when a buildpack url is specified" do
      let(:buildpack_url) { fake_buildpack_url("start_command") }
      let(:start_staging_message) {
        {
          "async" => false,
          "app_id" => "some-app-id",
          "properties" => {
            "buildpack" => buildpack_url
          },
          "download_uri" => unstaged_url,
          "upload_uri" => staged_url,
          "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
          "buildpack_cache_download_uri" => buildpack_cache_download_uri
        }
      }

      before { setup_fake_buildpack("start_command") }

      it "downloads the buildpack and runs it" do
        response = nats.request("staging", start_staging_message)

        response["error"].should be_nil
        response["task_log"].tap do |log|
          log.should include("-----> Downloaded app package (4.0K)\n")
          log.should include("-----> Some compilation output\n")
          log.should include("-----> Uploading staged droplet (12K)\n")
          log.should include("-----> Uploaded droplet\n")
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

      context "when staging is running" do
        let(:start_staging_message) {
          {
            "async" => true,
            "app_id" => "some-app-id",
            "properties" => {
              "buildpack" => buildpack_url
            },
            "download_uri" => unstaged_url,
            "upload_uri" => staged_url,
            "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
            "buildpack_cache_download_uri" => buildpack_cache_download_uri
          }
        }

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
        let(:start_staging_message) {
          {
            "async" => false,
            "app_id" => "some-app-id",
            "properties" => {
              "buildpack" => buildpack_url
            },
            "download_uri" => unstaged_url,
            "upload_uri" => "http://localhost:45459/not_real",
            "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
            "buildpack_cache_download_uri" => buildpack_cache_download_uri
          }
        }

        it "does not crash" do
          response = nats.request("staging", start_staging_message)
          response["error"].should include("Error uploading")
          dea_memory.should > 0
        end
      end
    end
  end

  describe "running staging tasks" do
    let(:buildpack_url) { fake_buildpack_url("long_compiling_buildpack") }
    let(:start_staging_message) {
      {
        "async" => async_staging,
        "app_id" => app_id,
        "properties" => {
          "buildpack" => buildpack_url
        },
        "download_uri" => unstaged_url,
        "upload_uri" => staged_url,
        "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
        "buildpack_cache_download_uri" => buildpack_cache_download_uri
      }
    }

    before { setup_fake_buildpack("long_compiling_buildpack") }

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
            response["error"].should eq("Error staging: task stopped")
            response["task_id"].should eq(task_id)
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
              response["error"].should eq("Error staging: task stopped")
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
          NATS.publish("staging.stop", Yajl::Encoder.encode({"app_id" => "some-app-id"}))
        end

        second_response = lambda do |response|
          response["error"].should eq("Error staging: task stopped")
        end

        nats.with_async_staging message, first_response, second_response
      end
    end
  end

  def download_tgz(url)
    Dir.mktmpdir do |dir|
      `curl --silent --show-error #{url} > #{dir}/staged_app.tgz`
      `cd #{dir} && tar xzvf staged_app.tgz`
      yield dir
    end
  end
end
