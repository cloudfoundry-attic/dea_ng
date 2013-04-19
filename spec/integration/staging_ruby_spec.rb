require "spec_helper"
require "net/http"

describe "Staging a ruby app", :type => :integration, :requires_warden => true do
  let(:nats) { NatsHelper.new }
  let(:unstaged_url) { "http://localhost:9999/unstaged/sinatra" }
  let(:staged_url) { "http://localhost:9999/staged/sinatra" }
  let(:start_staging_message) do
    {
        "async" => false,
        "app_id" => "some-ruby-app-id",
        "properties" => {},
        "download_uri" => unstaged_url,
        "upload_uri" => staged_url,
        "buildpack_cache_upload_uri" => "http://localhost:9999/buildpack_cache",
        "buildpack_cache_download_uri" => "http://localhost:9999/buildpack_cache"
    }
  end

  it "packages a ruby binary and the app's gems" do
    response = nats.request("staging", start_staging_message)

    expect(response["detected_buildpack"]).to eq("Ruby/Rack")
    expect(response["task_log"]).to include("Your bundle is complete!")
    expect(response["error"]).to be_nil

    download_tgz(staged_url) do |dir|
      expect(Dir.entries("#{dir}/app/vendor")).to include("ruby-1.9.2")
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