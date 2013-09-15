require "spec_helper"
require "net/http"
require "vcap/common"

describe "Directory server", :type => :integration, :requires_warden => true do
  it "asks dea to verify instance file paths" do
    result = Net::HTTP.get(URI.parse("http://#{dea_host}:34567/instance_paths/instance-id?path=/file"))
    result.should include("Invalid HMAC")
  end

  it "asks dea to verify staging tasks file paths" do
    result = Net::HTTP.get(URI.parse("http://#{dea_host}:34567/staging_tasks/task-id/file_path?path=/file"))
    result.should include("Invalid HMAC")
  end
end
