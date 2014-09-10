require "dea/starting/start_message"
require 'dea/staging/buildpacks_message'
require "steno"
require "steno/core_ext"

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
    BuildpacksMessage.new(@message["admin_buildpacks"]).buildpacks
  end

  def buildpack_git_url
    url = properties["buildpack"] || properties["buildpack_git_url"]
    URI(url) if url
  end

  def buildpack_key
    properties["buildpack_key"]
  end

  def egress_rules
    @message["egress_network_rules"] || []
  end

  def env
    properties["environment"] || []
  end

  def services
    properties["services"] || []
  end

  def vcap_application
    start_message.vcap_application
  end

  def mem_limit
    start_message.mem_limit
  end

  private

  def logger
    self.class.logger
  end
end
