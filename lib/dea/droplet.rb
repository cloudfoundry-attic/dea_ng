# coding: UTF-8

require "tempfile"
require "digest/sha1"
require "em-http"
require "steno"
require "steno/core_ext"

module Dea
  class Droplet
    class DownloadError < StandardError
      attr_reader :data

      def initialize(msg, data = {})
        @data = data

        super("error downloading: %s (%s)" % [uri, msg])
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
    end

    def droplet_directory
      File.join(base_dir, sha1)
    end

    def droplet_file
      File.join(droplet_directory, "droplet.tgz")
    end

    def droplet_exist?
      File.exist?(droplet_file)
    end

    def download(uri, &blk)
      @download_waiting ||= []
      @download_waiting << blk

      logger.debug "waiting for download to complete"

      if @download_waiting.size == 1
        # Fire off request when this is the first call to #download
        get(uri) do |err, path|
          if !err
            File.rename(path, droplet_file)
            File.chmod(0744, droplet_file)

            logger.debug "moved droplet to #{droplet_file}"
          end

          while blk = @download_waiting.shift
            blk.call(err)
          end
        end
      end
    end

    private

    def logger
      @logger ||= self.class.logger.tag(:sha1 => sha1)
    end

    def get(uri, &blk)
      FileUtils.mkdir_p(droplet_directory)

      file = Tempfile.new("droplet", droplet_directory)
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

      context = { :uri => uri }

      http.errback do
        cleanup.call do
          error = DownloadError.new("response status: unknown", context)
          logger.warn(error.message, error.data)
          blk.call(error)
        end
      end

      http.callback do
        cleanup.call do
          status = http.response_header.status

          context = context.merge(:status => status)

          if status == 200
            sha1_expected = self.sha1
            sha1_actual   = sha1.hexdigest

            if sha1_expected == sha1_actual
              blk.call(nil, file.path)
            else
              context = context.merge(
                :sha1_expected => sha1_expected,
                :sha1_actual   => sha1_actual
              )

              error = DownloadError.new("SHA1 mismatch", context)
              logger.warn(error.message, error.data)
              blk.call(error)
            end
          else
            error = DownloadError.new("response status: #{status}", context)
            logger.warn(error.message, error.data)
            blk.call(error)
          end
        end
      end
    end
  end
end
