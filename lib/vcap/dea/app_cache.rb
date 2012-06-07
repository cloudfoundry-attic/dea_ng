require 'logger'
require 'fileutils'
require 'digest/sha1'
require 'tmpdir'
require 'fiber_aware_helpers'
require 'http_util'

module VCAP module Dea end end

class VCAP::Dea::AppCache

  include VCAP::Dea::FiberAwareHelpers

  def initialize(directories, logger = nil)
    @logger = logger || Logger.new(STDOUT)
    @directories = directories
    @logger.debug("app cache initialized")
  end

  def list_droplets
    Dir.glob("#{@directories['droplets']}/*").map {|p| File.basename(p)}
  end

  def has_droplet?(sha1)
    File.exists? droplet_dir(sha1)
  end

  def droplet_dir(sha1)
    File.join(@directories['droplets'], sha1)
  end

  def purge_droplet!(sha1)
    defer do
      FileUtils.rm_rf droplet_dir(sha1), :secure => true
      @logger.debug "Purged droplet #{sha1}."
    end
  end

  def download_droplet(uri, sha1)
    if (!uri || !sha1)
      @logger.warn("missing uri or hash")
      raise VCAP::Dea::HandlerError, "Missing download information."
    end

    unless droplet_tgz_path = VCAP::Dea::HttpUtil.download(uri, @directories['tmp'])
      @logger.warn("Failed downloading droplet from '#{uri}'")
      raise VCAP::Dea::HandlerError, "Failed downloading droplet"
    end

    @logger.debug("finished downloading: #{uri}, size #{File.stat(droplet_tgz_path).size}")

    computed_sha1 = defer { Digest::SHA1.file(droplet_tgz_path).hexdigest }
    unless computed_sha1 == sha1
      @logger.warn("SHA1 mismatch for droplet (expected=#{sha1}, computed=#{computed_sha1})")
      raise VCAP::Dea::HandlerError, "SHA1 mismatch"
    end

    droplet_dir = File.join(@directories['droplets'], sha1)
    droplet_path = File.join(droplet_dir, 'droplet.tgz')
    FileUtils.mkdir_p(droplet_dir)
    File.rename(droplet_tgz_path, droplet_path)
    File.chmod(0744, droplet_path)

    @logger.debug("move droplet to #{droplet_path}")
  end

end

