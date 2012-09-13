# coding: UTF-8

require "json"
require "rack/test"
require "spec_helper"

require "dea/file_api"

describe Dea::FileApi do
  include Rack::Test::Methods

  let(:instance) do
    instance_mock = mock("instance_mock")
    instance_mock.stub(:instance_id).and_return("test_instance")
    instance_mock.stub(:instance_path).and_return("/foo/bar")
    instance_mock
  end

  let(:instance_registry) do
    registry = mock("instance_registry")
    registry.
      stub(:lookup_instance).
      with(instance.instance_id).
      and_return(instance)
    registry
  end

  let(:path_key) { "secret" }
  let(:max_url_age_secs) { 1 }

  before do
    Dea::FileApi.configure(instance_registry, path_key, max_url_age_secs)
  end

  def app
    Dea::FileApi
  end

  describe "verify_hmac_hexdigest" do
    it "should return true if the hmacs match" do
      Dea::FileApi.verify_hmac_hexdigest("foo", "foo").should be_true
    end

    it "should return false if the hmacs don't match" do
      Dea::FileApi.verify_hmac_hexdigest("foo", "bar").should be_false
    end
  end

  describe "GET /instance_paths/<instance_id>" do
    it "returns a 401 if the hmac is missing" do
      get_instance_path(:hmac => "")
      last_response.status.should == 401
      last_error.should == "Invalid HMAC"
    end

    it "returns a 400 if the timestamp is too old" do
      get_instance_path(:timestamp => Time.now.to_i - 60)
      last_response.status.should == 400
      last_error.should == "Url expired"
    end

    it "returns a 404 if no instance exists" do
      instance_registry.
        should_receive(:lookup_instance).
        with("nonexistant").
        and_return(nil)

      get_instance_path(:instance_id => "nonexistant")
      last_response.status.should == 404
      last_error.should == "Unknown instance"
    end

    it "returns a 503 if the instance path is unavailable" do
      instance.stub(:instance_path_available?).and_return(false)
      get_instance_path
      last_response.status.should == 503
      last_error.should == "Instance unavailable"
    end

    it "returns the full path on success" do
      instance.stub(:instance_path_available?).and_return(true)
      path = "/test/path"
      get_instance_path(:path => path)
      json_body["instance_path"].should == File.join(instance.instance_path, path)
    end
  end

  def get_instance_path(opts = {})
    path = opts[:path] || "/nonexistant"
    instance_id = opts[:instance_id] || instance.instance_id
    ts = opts[:timestamp] || Time.now
    hmac = opts[:hmac] || Dea::FileApi.create_hmac_hexdigest(instance_id, path, ts)
    get "/instance_paths/#{instance_id}?hmac=#{hmac}&timestamp=#{ts.to_i}&path=#{path}"
  end

  def json_body
    JSON.parse(last_response.body)
  end

  def last_error
    json_body.should be_kind_of(Hash)
    json_body["error"]
  end
end
