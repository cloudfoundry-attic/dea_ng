# coding: UTF-8

require "spec_helper"
require "json"
require "rack/test"
require "dea/directory_server_v2"

describe Dea::DirectoryServerV2::InstancePaths do
  include Rack::Test::Methods
  include_context "tmpdir"

  let(:instance_registry) do
    mock("instance_registry").tap do |r|
      r.stub(:lookup_instance).with(instance.instance_id).and_return(instance)
    end
  end

  let(:instance) do
    mock("instance_mock").tap do |i|
      i.stub(:instance_id => "test_instance", :instance_path => tmpdir)
    end
  end

  let(:config) { {"directory_server" => {"file_api_port" => 1234}} }
  let(:directory_server) { Dea::DirectoryServerV2.new("example.org", 1234, config) }

  before { Dea::DirectoryServerV2::InstancePaths.configure(directory_server, instance_registry, 1) }

  describe "GET /instance_paths/<instance_id>" do
    it "returns a 401 if the hmac is missing" do
      get instance_path(instance.instance_id, "/path", :hmac => "")
      last_response.status.should == 401
      last_error.should == "Invalid HMAC"
    end

    it "returns a 400 if the timestamp is too old" do
      Time.stub(:now => Time.at(10))
      url = instance_path(instance.instance_id, "/path")

      Time.stub(:now => Time.at(12))
      get url

      last_response.status.should == 400
      last_error.should == "Url expired"
    end

    it "returns a 404 if no instance exists" do
      instance_registry.
        should_receive(:lookup_instance).
        with("unknown-instance-id").
        and_return(nil)

      get instance_path("unknown-instance-id", "/path")
      last_response.status.should == 404
      last_error.should == "Unknown instance"
    end

    context "when instance path is not available" do
      before { instance.stub(:instance_path_available?).and_return(false) }

      it "returns a 503 if the instance path is unavailable" do
        get instance_path(instance.instance_id, "/path")
        last_response.status.should == 503
        last_error.should == "Instance unavailable"
      end
    end

    context "when instance path is available" do
      before { instance.stub(:instance_path_available?).and_return(true) }

      it "returns 404 if the requested file doesn't exist" do
        get instance_path(instance.instance_id, "/unknown-path")
        last_response.status.should == 404
      end

      it "returns 403 if the file points outside the instance directory" do
        get instance_path(instance.instance_id, "/..")
        last_response.status.should == 403
      end

      it "returns 200 with full path on success" do
        path = File.join(tmpdir, "test")
        FileUtils.touch(path)

        get instance_path(instance.instance_id, "/test")
        json_body["instance_path"].should == File.join(instance.instance_path, "test")
      end

      it "return 200 with instance path when path is not explicitly specified (nil)" do
        get directory_server.instance_file_url_for(instance.instance_id, nil)
        last_response.status.should == 200
        json_body["instance_path"].should == instance.instance_path
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
    json_body.should be_kind_of(Hash)
    json_body["error"]
  end
end
