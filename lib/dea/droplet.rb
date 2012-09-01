# coding: UTF-8

require "digest/sha1"
require "em-http"
require "fileutils"
require "steno"
require "steno/core_ext"
require "tempfile"

module Dea
  class Droplet
    class DownloadError < StandardError
      attr_reader :data

      def initialize(msg, data = {})
        @data = data

        super("Error downloading: %s (%s)" % [uri, msg])
      end

      def uri
        data[:uri] || "(unknown)"
      end
    end

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
        get(uri) do |err, path|
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

    def destroy(&blk)
      dir_to_remove = droplet_dirname + ".deleted." + Time.now.to_i.to_s

      # Rename first to both prevent a new instance from referencing a file
      # that is about to be deleted and to avoid doing a potentially expensive
      # operation on the reactor thread.
      logger.debug("Renaming #{droplet_dirname} to #{dir_to_remove}")
      File.rename(droplet_dirname, dir_to_remove)

      EM.defer do
        logger.debug("Removing #{dir_to_remove}")
        FileUtils.rm_rf(dir_to_remove)
        blk.call if blk
      end
    end

    private

    def logger
      @logger ||= self.class.logger.tag(:droplet_sha1 => sha1)
    end

    def get(uri, &blk)
      FileUtils.mkdir_p(droplet_dirname)

      file = Tempfile.new("droplet", droplet_dirname)
      sha1 = Digest::SHA1.new

      http = EM::HttpRequest.new(uri).get

      http.stream do |chunk|
        file << chunk
        sha1 << chunk
      end

      cleanup = lambda do |&inner|
        file.close

        begin
          inner.call
        ensure
          File.unlink(file.path) if File.exist?(file.path)
        end
      end

      context = { :droplet_uri => uri }

      http.errback do
        cleanup.call do
          error = DownloadError.new("Response status: unknown", context)
          logger.warn(error.message, error.data)
          blk.call(error)
        end
      end

      http.callback do
        cleanup.call do
          http_status = http.response_header.status

          context[:droplet_http_status] = http_status

          if http_status == 200
            sha1_expected = self.sha1
            sha1_actual   = sha1.hexdigest

            if sha1_expected == sha1_actual
              blk.call(nil, file.path)
            else
              context[:droplet_sha1_expected] = sha1_expected
              context[:droplet_sha1_actual]   = sha1_actual

              error = DownloadError.new("SHA1 mismatch", context)
              logger.warn(error.message, error.data)
              blk.call(error)
            end
          else
            error = DownloadError.new("HTTP status: #{http_status}", context)
            logger.warn(error.message, error.data)
            blk.call(error)
          end
        end
      end
    end
  end
end
