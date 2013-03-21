require "spec_helper"
require "zip/zip"

describe "Staging an app", :type => :integration, :requires_warden => true do
  let(:nats) { NatsHelper.new }
  let!(:fake_file_server) { FakeFileServer.start! }

  describe "staging a simple sinatra app" do
    let(:unstaged_url) { "http://localhost:9999/unstaged/sinatra" }
    let(:staged_url) { "http://localhost:9999/staged/sinatra" }

    it "works" do
      response = nats.request("staging", {
        "async" => false,
        "app_id" => "some-app-id",
        "properties" => {},
        "download_uri" => unstaged_url,
        "upload_uri" => staged_url
      })

      response["task_log"].should include("Your bundle is complete!")
      response["error"].should be_nil

      File.write = Net::HTTP.get(staged_url)
      fake_file_server.droplet[:filename].should eq "droplet.tgz"

      system "curl #{staged_url} | tar xvf"
      #http = Patron::Session.new
      #http.base_url = "http://localhost:9999"
      #resp = http.get("staged/sinatra")

      puts resp

      #Zip::Zipfile.open(fake_file_server.droplet[:tempfile]) do |zipfile|
      #  zipfile.entries.map(&:path).should include "vendor/foobar"
      #end
    end
  end
end
