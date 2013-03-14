require "spec_helper"

describe "Staging an app", :type => :integration, :requires_warden => true do
  let(:nats) { NatsHelper.new }

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
    end
  end
end
