require "spec_helper"

describe "Staging an app", :type => :integration, :requires_warden => true do
  let(:nats) { NatsHelper.new }

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
          Dir.entries("#{dir}/app/vendor/bundle/ruby/1.9.1/gems").should =~ %w(
            .
            ..
            bundler-1.3.2
            rack-1.5.1
            rack-protection-1.3.2
            sinatra-1.3.4
            tilt-1.3.3
          )
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
    end

    def download_tgz(url)
      Dir.mktmpdir do |dir|
        `curl --silent --show-error #{url} > #{dir}/staged_app.tgz`
        `cd #{dir} && tar xzvf staged_app.tgz`
        yield dir
      end
    end
  end
end
