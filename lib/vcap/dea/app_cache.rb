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

    unless droplet_tgz_path = VCAP::Dea::HttpUtil.download(uri)
      @logger.warn("Failed downloading droplet from '#{uri}'")
      raise VCAP::Dea::HandlerError, "Failed downloading droplet"
    end

    @logger.debug("finished downloading: #{uri}, size #{File.stat(droplet_tgz_path).size}")

    computed_sha1 = defer { Digest::SHA1.file(droplet_tgz_path).hexdigest }
    unless computed_sha1 == sha1
      @logger.warn("SHA1 mismatch for droplet (expected=#{sha1}, computed=#{computed_sha1})")
      raise VCAP::Dea::HandlerError, "SHA1 mismatch"
    end

    tmp_dir = Dir.mktmpdir(nil, @directories['tmp'])
    droplet_dir = File.join(@directories['droplets'], sha1)
    status, stdout, stderr = sh("tar -C #{tmp_dir} -xzf #{droplet_tgz_path}")
    if status.exitstatus == 0
      @logger.debug("unpacked droplet to #{tmp_dir}.")
    else
      @logger.warn("Failed extracting #{droplet_tgz_path}")
      @logger.warn("STDOUT: #{stdout}")
      @logger.warn("STDERR: #{stderr}")
      raise VCAP::Dea::HandlerError, "Droplet extraction failed"
    end
    File.rename(tmp_dir, droplet_dir)
    @logger.debug "moved droplet to #{droplet_dir}."
  rescue
    defer { FileUtils.rm_rf(tmp_dir) } if tmp_dir
    raise

  ensure
    defer { FileUtils.rm_f(droplet_tgz_path) } if droplet_tgz_path
  end

end

