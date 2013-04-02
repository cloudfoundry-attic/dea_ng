require "spec_helper"

describe "Staging an app", :type => :integration, :requires_warden => true do
  let(:nats) { NatsHelper.new }

  describe "staging a simple nodejs app" do
    let(:unstaged_url) { "http://localhost:9999/unstaged/app_with_procfile" }
    let(:staged_url) { "http://localhost:9999/staged/app_with_procfile" }

    it "packages up the node dependencies and stages the app properly" do
      response = nats.request("staging", {
          "async" => false,
          "app_id" => "some-node-app-id",
          "properties" => {},
          "download_uri" => unstaged_url,
          "upload_uri" => staged_url
      })

      expect(response["task_log"]).to include("Resolving engine versions")
      expect(response["task_log"]).to include("Fetching Node.js binaries")
      expect(response["task_log"]).to include("Vendoring node into slug")
      expect(response["task_log"]).to include("Installing dependencies with npm")
      expect(response["task_log"]).to include("Building runtime environment")
      expect(response["error"]).to be_nil

      download_tgz(staged_url) do |dir|
        entries = Dir.entries(dir)
        expect(entries).to include("nodejs-0.10.1.tgz")
        expect(entries).to include("scons-1.2.0.tgz")
        expect(entries).to include("npm-1.2.15.tgz")
        expect(entries).to include("nodejs-0.4.7.tgz")
      end
    end

    context "when dependencies have incompatible versions" do
      let(:unstaged_url) { "http://localhost:9999/unstaged/node_with_incompatibility" }
      let(:staged_url) { "http://localhost:9999/staged/node_with_incompatibility" }

      it "fails to stage" do
        response = nats.request("staging", {
            "async" => false,
            "app_id" => "some-node-app-id",
            "properties" => {},
            "download_uri" => unstaged_url,
            "upload_uri" => staged_url
        })

        expect(response["error"]).to include "Script exited with status 1"
        # Bcrypt 0.4.1 is incompatible with node 0.10, using node-waf and node-gyp respectively
        expect(response["task_log"]).to include("make: node-waf: Command not found")
        expect(response["task_log"]).to_not include("Building runtime environment")
      end
    end
  end

  describe "staging a simple sinatra app" do
    let(:unstaged_url) { "http://localhost:9999/unstaged/sinatra" }
    let(:staged_url) { "http://localhost:9999/staged/sinatra" }

    context "when the DEA has to detect the buildback" do
      it "packages a ruby binary and the app's gems" do
        response = nats.request("staging", {
          "async" => false,
          "app_id" => "some-app-id",
          "properties" => {},
          "download_uri" => unstaged_url,
          "upload_uri" => staged_url
        })

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
    end

    context "when a buildpack url is specified" do
      let(:buildpack_url) { fake_buildpack_url("start_command") }

      before { setup_fake_buildpack("start_command") }

      it "downloads the buildpack and runs it" do
        response = nats.request("staging", {
          "async" => false,
          "app_id" => "some-app-id",
          "properties" => {
            "buildpack" => buildpack_url
          },
          "download_uri" => unstaged_url,
          "upload_uri" => staged_url
        })

        response["error"].should be_nil
        response["task_log"].tap do |log|
          log.should include("-----> Downloaded app package (4.0K)\n")
          log.should include("-----> Some compilation output\n")
          log.should include("-----> Uploading staged droplet (12K)\n")
          log.should include("-----> Uploaded droplet\n")
        end
      end

      it "decreases the DEA's available memory" do
        expect {
          nats.request("staging", {
            "async" => true,
            "app_id" => "some-app-id",
            "properties" => {
              "buildpack" => buildpack_url
            },
            "download_uri" => unstaged_url,
            "upload_uri" => staged_url
          })
        }.to change { dea_memory }.by(-1024)
      end

      context "when a invalid upload URI is given" do
        it "does not crash" do
          response = nats.request("staging", {
            "async" => false,
            "app_id" => "some-app-id",
            "properties" => {
              "buildpack" => buildpack_url
            },
            "download_uri" => unstaged_url,
            "upload_uri" => "http://localhost:45459/not_real"
          })

          response["error"].should include("Error uploading")
          dea_memory.should > 0
        end
      end
    end

    context "when the shutdown started" do
      let(:buildpack_url) { fake_buildpack_url("long_compiling_buildpack") }
      let(:async_staging) { false }
      let(:start_staging_message) do
        {
          "async" => async_staging,
          "app_id" => "some-app-id",
          "properties" => {
            "buildpack" => buildpack_url
          },
          "download_uri" => unstaged_url,
          "upload_uri" => staged_url
        }
      end

      before do
        setup_fake_buildpack("long_compiling_buildpack")
      end

      context "when asynchronous staging is in process" do
        let(:async_staging) { true }
        it "stops staging tasks" do
          message = Yajl::Encoder.encode(start_staging_message)
          task_id = nil
          NATS.start do
            sid = NATS.request("staging", message, :max => 3) do |response|
              response = Yajl::Parser.parse(response)
              # Send SHUTDOWN after first response
              if response["task_streaming_log_url"]
                task_id = response["task_id"]
                Process.kill("USR2", dea_pid)
              end

              if response["error"]
                NATS.stop do
                  response["error"].should eq("Error staging: task stopped")
                  response["task_id"].should eq(task_id)
                end
              end
            end
            NATS.timeout(sid, 10, :expected => 2) { raise "Staging task did not stop within timeout" }
          end
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
  end

  def download_tgz(url)
    Dir.mktmpdir do |dir|
      `curl --silent --show-error #{url} > #{dir}/staged_app.tgz`
      `cd #{dir} && tar xzvf staged_app.tgz`
      yield dir
    end
  end
end
