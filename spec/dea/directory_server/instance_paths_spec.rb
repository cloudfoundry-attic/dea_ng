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
      get instance_path(:hmac => "")
      last_response.status.should == 401
      last_error.should == "Invalid HMAC"
    end

    it "returns a 400 if the timestamp is too old" do
      Time.stub(:now => Time.at(10))
      url = instance_path

      Time.stub(:now => Time.at(12))
      get url

      last_response.status.should == 400
      last_error.should == "Url expired"
    end

    it "returns a 404 if no instance exists" do
      instance_registry.
        should_receive(:lookup_instance).
        with("nonexistant").
        and_return(nil)

      get instance_path(:instance_id => "nonexistant")
      last_response.status.should == 404
      last_error.should == "Unknown instance"
    end

    it "returns a 503 if the instance path is unavailable" do
      instance.stub(:instance_path_available?).and_return(false)
      get instance_path
      last_response.status.should == 503
      last_error.should == "Instance unavailable"
    end

    it "returns 404 if the requested file doesn't exist" do
      instance.stub(:instance_path_available?).and_return(true)
      get instance_path
      last_response.status.should == 404
    end

    it "returns 403 if the file points outside the instance directory" do
      instance.stub(:instance_path_available?).and_return(true)
      get instance_path(:path => "/..")
      last_response.status.should == 403
    end

    it "returns the full path on success" do
      instance.stub(:instance_path_available?).and_return(true)

      path = File.join(tmpdir, "test")
      FileUtils.touch(path)

      get instance_path(:path => "/test")
      json_body["instance_path"].should == File.join(instance.instance_path, "test")
    end
  end

  alias_method :app, :described_class

  def instance_path(opts = {})
    hmaced_url = directory_server.file_url_for(
      opts[:instance_id] || instance.instance_id,
      opts[:path] || "/nonexistant"
    )

    if opts[:hmac]
      hmaced_url.gsub!(/hmac=.+([^\&]|$)/, "hmac=#{opts[:hmac]}")
    end

    hmaced_url
  end

  def json_body
    JSON.parse(last_response.body)
  end

  def last_error
    json_body.should be_kind_of(Hash)
    json_body["error"]
  end
end
