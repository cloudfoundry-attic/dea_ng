require "spec_helper"
require "timeout"
require "yajl"
require "digest/sha1"

describe "Logging", :type => :integration do
  describe "starting an app" do
    it "works" do
      dea_id = request_nats("dea.discover", {
        "limits" => { "mem" => 1, "disk" => 1 },
        "droplet" => "asdf-asdf-asdf-asdf"
      })["id"]

      publish_nats("dea.#{dea_id}.start", {
        "executableUri" => "http://localhost:9999/fake_app.rb",
        "sha1" => file_sha1(File.expand_path("../../fixtures/fake_app.rb", __FILE__)),
        "index" => 1,
        "version" => "2.0",
        "name" => "my_app",
        "cc_partition" => "1",
        "limits" => { "mem" => 1, "disk" => 1, "fds" => 1 },
        "services" => []
      })
    end
  end

  def request_nats(key, data)
    write_nats(:request, key, data)
  end

  def publish_nats(key, data)
    write_nats(:publish, key, data)
  end

  def write_nats(method, key, data)
    response = nil
    NATS.start do
      NATS.public_send(method, key, Yajl::Encoder.encode(data)) do |resp|
        response = resp
        NATS.stop
      end
    end
    Yajl::Parser.parse(response) if response
  end

  def file_sha1(path)
    Digest::SHA1.hexdigest(File.read(path))
  end
end