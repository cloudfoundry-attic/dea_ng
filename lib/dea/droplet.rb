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
    attr_reader :app_name
    attr_reader :app_space
    attr_reader :app_org

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
            File.chmod(0755, droplet_path)

            logger.debug "Moved droplet to #{droplet_path}"
          end

          while blk = @download_waiting.shift
            blk.call(err)
          end
        end
      end
    end
    def unzip_droplet_dir
        File.join(base_dir,"../unzip_droplet")
    end

    def seed_file
        File.join(base_dir,"../tmpseed.torrent")
    end

    def download_unzip_droplet(infohash,&blk)
      @download_waiting ||= []
      @download_waiting << blk

      logger.debug "Waiting for download to complete"

      if @download_waiting.size == 1
        # Fire off request when this is the first call to #download
        unzip_droplet_dir=File.join(base_dir,"../unzip_droplet")
        FileUtils.mkdir_p(unzip_droplet_dir) unless File.exists?(unzip_droplet_dir)
        system("gko3 sdown -i #{infohash} -p #{unzip_droplet_dir} -d 15 -u 15 --seedtime 5 --save-torrent #{seed_file}")
        if $?.success?
            err=nil
            logger.debug "Download unzip droplet to #{unzip_droplet_dir}"
            #delete extra files if necessary
            system("gko3 rmfiles -p #{unzip_droplet_dir} -r #{seed_file} --not-in")
            if $?.success?
                err=nil
                logger.debug "delete extra files ok"
            else
                err="Failed to delete extra files"
            end
        else
            err="Failed to download unzip droplet:gko3 sdown -i #{infohash} -p #{unzip_droplet_dir} -d 15 -u 15"
        end
        while blk = @download_waiting.shift
            blk.call(err)
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
