require "dea/starting/start_message"

class StagingMessage
  def initialize(message)
    @message = message
  end

  def to_hash
    @message
  end

  def app_id
    @message["app_id"]
  end

  def properties
    @message["properties"] || {}
  end

  def task_id
    @message["task_id"]
  end

  def download_uri
    URI(@message["download_uri"]) if @message["download_uri"]
  end

  def upload_uri
    URI(@message["upload_uri"]) if @message["upload_uri"]
  end

  def buildpack_cache_upload_uri
    URI(@message["buildpack_cache_upload_uri"]) if @message["buildpack_cache_upload_uri"]
  end

  def buildpack_cache_download_uri
    URI(@message["buildpack_cache_download_uri"]) if @message["buildpack_cache_download_uri"]
  end

  def start_message
    @start_message ||= StartMessage.new(@message["start_message"])
  end

  def admin_buildpacks
    (@message["admin_buildpacks"] || []).map do |buildpack|
      { url: URI(buildpack["url"]), key: buildpack["key"] }
    end
  end
end