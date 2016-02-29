# coding: UTF-8

require "digest/sha1"
require "em-http"
require "fileutils"
require "steno"
require "steno/core_ext"
require "tempfile"
require "dea/utils/download"

module Dea
  class Droplet
    attr_reader :base_dir
    attr_reader :sha1

    def initialize(base_dir, sha1)
      @base_dir = base_dir
      @sha1 = sha1
      @pending_downloads = []

      # Make sure the directory exists
      FileUtils.mkdir_p(droplet_dirname)
    end

    def droplet_dirname
      File.expand_path(File.join(base_dir, sha1))
    end

    def droplet_basename
      "droplet.tgz"
    end

    def droplet_path
      File.join(droplet_dirname, droplet_basename)
    end

    def exists?
      File.exists?(droplet_path) && \
        Digest::SHA1.file(droplet_path).hexdigest == @sha1
    end

    def download(uri, &blk)
      if exists?
        blk.call(nil)
        return
      end

      # ensure only one download is happening for a single droplet.
      # this keeps 100 starts from causing a network storm.
      #
      # we do this by only having the first download attempt actually download,
      # and just call the other callbacks when it's done.
      is_first_downloader = register_downloader(blk)

      return unless is_first_downloader

      download_destination = Tempfile.new("droplet-download.tgz")

      Download.new(uri, download_destination, sha1).download! do |err|
        unless err
          FileUtils.mkdir_p(droplet_dirname)
          File.rename(download_destination.path, droplet_path)
          File.chmod(0744, droplet_path)
        end

        with_pending_downloads do |pending_downloads|
          while pending = pending_downloads.shift
            pending.call(err)
          end
        end
      end
    end

    def local_copy(source, &blk)
      logger.debug "Copying local droplet to droplet registry"
      begin
        FileUtils.cp(source, droplet_path)
        blk.call
      rescue => e
        blk.call(e)
      end
    end

    def destroy(&callback)
      if !droplet_dirname.include?('.deleted.')
        # Rename first to both prevent a new instance from referencing a file
        # that is about to be deleted and to avoid doing a potentially expensive
        # operation on the reactor thread.
        dir_to_remove = droplet_dirname + ".deleted." + Time.now.to_i.to_s 
        logger.debug("Renaming #{droplet_dirname} to #{dir_to_remove}")
        begin
          File.rename(droplet_dirname, dir_to_remove)
        rescue SystemCallError => e
          logger.debug("Already renamed #{droplet_dirname}", error: e)
          return
        end
      else 
        dir_to_remove = droplet_dirname
      end

      operation = lambda do
        logger.debug("Removing #{dir_to_remove}")

        begin
          FileUtils.rm_r(dir_to_remove)
        rescue => e
          logger.log_exception(e)
        end
      end

      EM.defer(operation, callback)
    end

    private

    DOWNLOAD_PENDING = Mutex.new

    def register_downloader(callback)
      with_pending_downloads do
        should_download = @pending_downloads.empty?
        @pending_downloads << callback
        should_download
      end
    end

    def with_pending_downloads
      DOWNLOAD_PENDING.synchronize do
        yield @pending_downloads
      end
    end

    def logger
      @logger ||= self.class.logger.tag(droplet_sha1: sha1)
    end
  end
end
