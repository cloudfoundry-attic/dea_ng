require "spec_helper"
require "net/http"

describe "Staging a rails app", :type => :integration, :requires_warden => true do
  let(:unstaged_url) { "http://#{file_server_address}/unstaged/rails3_with_db" }
  let(:staged_url) { "http://#{file_server_address}/staged/rails3_with_db" }
  let(:properties) { {} }
  let(:app_id) { "some-rails-app-id" }
  let(:cleardb_service) do
    valid_service_attributes.merge("label" => "cleardb", "credentials" => { "uri" => "mysql2://some_user:some_password@some-db-provider.com:3306/db_name"})
  end

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
      "app_id" => app_id,
      "properties" => { "services" => [cleardb_service] },
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => "http://#{file_server_address}/buildpack_cache",
      "buildpack_cache_download_uri" => "http://#{file_server_address}/buildpack_cache",
      "start_message" => start_message
    }
  end

  it "runs a rails 3 app" do
    by "staging the app" do
      response, log = perform_stage_request(staging_message)

      expect(response["detected_buildpack"]).to eq("Ruby/Rails")
      expect(response["error"]).to be_nil

      expect(log).to include("Your bundle is complete!")

      download_tgz(staged_url) do |dir|
        expect(Dir.entries("#{dir}/app/vendor")).to include("ruby-1.9.3")
      end
    end

    and_by "starting the app" do
      download_tgz(staged_url) do |dir|
        staging_info = File.read("#{dir}/staging_info.yml")
        expect(staging_info).to include('start_command: ')
        expect(staging_info).to include('detected_buildpack: ')
      end
    end
  end
end
