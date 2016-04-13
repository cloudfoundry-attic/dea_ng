require "spec_helper"
require "net/http"

describe "Directory server", :type => :integration, :requires_warden => true do
  let(:dir_server_port)  { dea_config['directory_server']['v2_port'] }
  it "asks dea to verify instance file paths" do
    result = Net::HTTP.get(URI.parse("http://#{dea_host}:#{dir_server_port}/instance_paths/instance-id?path=/file&hmac=&timestamp=0"))
    expect(result).to include("Invalid HMAC")
  end

  it "asks dea to verify staging tasks file paths" do
    result = Net::HTTP.get(URI.parse("http://#{dea_host}:#{dir_server_port}/staging_tasks/task-id/file_path?path=/file&hmac=&timestamp=0"))
    expect(result).to include("Invalid HMAC")
  end
end
