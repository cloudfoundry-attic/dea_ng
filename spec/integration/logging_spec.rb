require "spec_helper"
require "timeout"
require "yajl"
require "digest/sha1"
require "patron"

describe "Logging", :type => :integration, :requires_erlang => true do
  describe "starting an app" do
    let(:nats) { NatsHelper.new }

    xit "works" do
      dea_id = nats.request("dea.discover", {
        "droplet" => "droplet-id",
        "limits" => {
          "mem" => 1,
          "disk" => 1
        },
      })["id"]

      nats.publish("dea.#{dea_id}.start", {
        "executableUri" => "http://localhost:9999/fake_app.rb",
        "sha1" => file_sha1(File.expand_path("../../fixtures/fake_app.rb", __FILE__)),
        "index" => 1,
        "version" => "2.0",
        "name" => "my_app",
        "cc_partition" => "1",
        "services" => [],
        "limits" => {
          "mem" => 1,
          "disk" => 1,
          "fds" => 1
        },
      })

      http = Patron::Session.new
      http.headers["Authorization"] = "Basic auth_key"
      http.base_url = "http://localhost:8601"
      expect(http.get("/healthcheck").body).to include("OK")
    end
  end

  def file_sha1(path)
    Digest::SHA1.hexdigest(File.read(path))
  end
end
