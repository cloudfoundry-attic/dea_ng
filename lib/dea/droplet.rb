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

    def droplet_exist?
      File.exist?(droplet_path)
    end

    def download(uri, &blk)
      @download_waiting ||= []
      @download_waiting << blk

      logger.debug "Waiting for download to complete"

      if @download_waiting.size == 1
        # Fire off request when this is the first call to #download
        Download.new(uri, droplet_dirname, sha1).download! do |err, path|
          if !err
            File.rename(path, droplet_path)
            File.chmod(0744, droplet_path)

            logger.debug "Moved droplet to #{droplet_path}"
          end

          while blk = @download_waiting.shift
            blk.call(err)
          end
        end
      end
    end

    def destroy(&callback)
      dir_to_remove = droplet_dirname + ".deleted." + Time.now.to_i.to_s

      # Rename first to both prevent a new instance from referencing a file
      # that is about to be deleted and to avoid doing a potentially expensive
      # operation on the reactor thread.
      logger.debug("Renaming #{droplet_dirname} to #{dir_to_remove}")
      File.rename(droplet_dirname, dir_to_remove)

      operation = lambda do
        logger.debug("Removing #{dir_to_remove}")

        begin
          FileUtils.rm_rf(dir_to_remove)
        rescue => e
          logger.log_exception(e)
        end
      end

      EM.defer(operation, callback)
    end

    private

    def logger
      @logger ||= self.class.logger.tag(:droplet_sha1 => sha1)
    end
  end
end
