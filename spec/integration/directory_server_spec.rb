require "spec_helper"
require "net/http"

describe "Directory server", :type => :integration, :requires_warden => true do
  it "asks dea to verify instance file paths" do
    result = Net::HTTP.get(URI.parse("http://localhost:5678/instance_paths/instance-id?path=/file"))
    result.should include("Invalid HMAC")
  end

  it "asks dea to verify staging tasks file paths" do
    result = Net::HTTP.get(URI.parse("http://localhost:5678/staging_tasks/task-id/file_path?path=/file"))
    result.should include("Invalid HMAC")
  end
end
