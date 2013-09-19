require "spec_helper"
require "net/http"

describe "Staging a ruby app", :type => :integration, :requires_warden => true do
  let(:unstaged_url) { "http://#{file_server_address}/unstaged/sinatra" }
  let(:staged_url) { "http://#{file_server_address}/staged/sinatra" }
  let(:properties) { {} }

  let(:start_message) do
    {
      "index" => 1,
      "droplet" => "some-app-id",
      "version" => "some-version",
      "name" => "some-app-name",
      "uris" => [],
      "prod" => false,
      "sha1" => nil,
      "executableUri" => nil,
      "cc_partition" => "foo",
      "limits" => {
        "mem" => 64,
        "disk" => 128,
        "fds" => 32
      },
      "services" => []
    }
  end

  let(:staging_message) do
    {
      "app_id" => "some-ruby-app-id",
      "properties" => properties,
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => "http://#{file_server_address}/buildpack_cache",
      "buildpack_cache_download_uri" => "http://#{file_server_address}/buildpack_cache",
      "start_message" => start_message
    }
  end

  it "packages a ruby binary and the app's gems" do
    response, log = perform_stage_request(staging_message)

    expect(response["detected_buildpack"]).to eq("Ruby/Rack")
    expect(response["error"]).to be_nil

    expect(log).to include("Your bundle is complete!")

    download_tgz(staged_url) do |dir|
      expect(Dir.entries("#{dir}/app/vendor")).to include("ruby-1.9.3")
      expect(Dir.entries("#{dir}/app/vendor/bundle/ruby/1.9.1/gems")).to match_array %w[
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
