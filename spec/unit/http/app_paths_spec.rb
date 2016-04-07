# coding: UTF-8

require "spec_helper"
require "json"
require "rack/test"
require 'dea/http/httpserver'
require 'dea/bootstrap'

describe Dea::Http::AppPaths do
  include Rack::Test::Methods

  alias_method :app, :described_class

  let(:bootstrap) { double(Dea::Bootstrap) }
  ca_cert = fixture("/certs/ca.crt")
  before { Dea::Http::AppPaths.configure(bootstrap) }

  describe "POST /v1/stage" do
    it "returns a 202" do
      data = {'foo' => 'bar'}
      expect(bootstrap).to receive(:stage_app_request).with(data)

      post 'https://127.0.0.1:1234/v1/stage', data.to_json, 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(202)
    end
  end

  describe "POST /v1/apps" do
    it "returns a 202" do
      data = {'foo' => 'bar'}
      expect(bootstrap).to receive(:start_app).with(data)

      post 'http://127.0.0.1:1234/v1/apps', data.to_json, 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(202)
    end
  end
end
