# coding: UTF-8

require "spec_helper"
require "json"
require "rack/test"
require "dea/directory_server/directory_server_v2"

describe Dea::DirectoryServerV2::InstancePaths do
  include Rack::Test::Methods
  include_context "tmpdir"

  let(:instance_registry) do
    double("instance_registry").tap do |r|
      allow(r).to receive(:lookup_instance).with(instance.instance_id).and_return(instance)
    end
  end

  let(:instance) do
    double("instance_mock").tap do |i|
      allow(i).to receive(:instance_id).and_return("test_instance")
      allow(i).to receive(:instance_path).and_return(tmpdir)
    end
  end

  let(:config) { {"directory_server" => {"file_api_port" => 1234, "protocol" => "http"}} }
  let(:directory_server) { Dea::DirectoryServerV2.new("example.org", 1234, nil, config) }

  before { Dea::DirectoryServerV2::InstancePaths.configure(directory_server, instance_registry, 1) }

  describe "GET /instance_paths/<instance_id>" do
    it "returns a 401 if the hmac is missing" do
      get instance_path(instance.instance_id, "/path", :hmac => "") + "&path=application&timestamp=0"
      expect(last_response.status).to eq(401)
      expect(last_error).to eq("Invalid HMAC")
    end

    it "returns a 400 if the timestamp is too old" do
      allow(Time).to receive(:now).and_return(Time.at(10))
      url = instance_path(instance.instance_id, "/path")

      allow(Time).to receive(:now).and_return(Time.at(12))
      get url

      expect(last_response.status).to eq(400)
      expect(last_error).to eq("Url expired")
    end

    it "returns a 404 if no instance exists" do
      allow(instance_registry).to receive(:lookup_instance).with("unknown-instance-id").and_return(nil)

      get instance_path("unknown-instance-id", "/path")
      expect(last_response.status).to eq(404)
      expect(last_error).to eq("Unknown instance")
    end

    context "when instance path is not available" do
      before { allow(instance).to receive(:instance_path_available?).and_return(false) }

      it "returns a 503 if the instance path is unavailable" do
        get instance_path(instance.instance_id, "/path")
        expect(last_response.status).to eq(503)
        expect(last_error).to eq("Instance unavailable")
      end
    end

    context "when instance path is available" do
      before { allow(instance).to receive(:instance_path_available?).and_return(true) }

      it "returns 404 if the requested file doesn't exist" do
        get instance_path(instance.instance_id, "/unknown-path")
        expect(last_response.status).to eq(404)
      end

      it "returns 403 if the file points outside the instance directory" do
        get instance_path(instance.instance_id, "/..")
        expect(last_response.status).to eq(403)
      end

      it "returns 200 with full path on success" do
        path = File.join(tmpdir, "test")
        FileUtils.touch(path)

        get instance_path(instance.instance_id, "/test")
        expect(json_body["instance_path"]).to eq(File.join(instance.instance_path, "test"))
      end

      it "return 200 with instance path when path is not explicitly specified (nil)" do
        get directory_server.instance_file_url_for(instance.instance_id, nil)
        expect(last_response.status).to eq(200)
        expect(json_body["instance_path"]).to eq(instance.instance_path)
      end
    end
  end

  alias_method :app, :described_class

  def instance_path(instance_id, path, opts = {})
    directory_server.instance_file_url_for(instance_id, path).tap do |url|
      url.gsub!(/hmac=.+([^\&]|$)/, "hmac=#{opts[:hmac]}") if opts[:hmac]
    end
  end

  def json_body
    JSON.parse(last_response.body)
  end

  def last_error
    expect(json_body).to be_kind_of(Hash)
    json_body["error"]
  end
end
