require "tempfile"
require "digest/sha1"
require "em-http"

module Dea
  class Droplet
    class DownloadError < StandardError
      def initialize(options)
        @options = options
      end

      def message
        reason = @options[:reason]
        reason ||= "response status: %s" % [@options[:status] || "unknown"]
        "error downloading: %s (%s)" % [@options[:uri], reason]
      end
    end

    attr_reader :base_path
    attr_reader :sha1

    def initialize(base_path, sha1)
      @base_path = base_path
      @sha1 = sha1
    end

    def droplet_directory
      File.join(base_path, sha1)
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

      if @download_waiting.size == 1
        # Fire off request when this is the first call to #download
        http_get(uri) do |err, path|
          if !err
            File.rename(path, droplet_file)
            File.chmod(0744, droplet_file)
          end

          while blk = @download_waiting.shift
            blk.call(err)
          end
        end
      end
    end

    private

    def http_get(uri, &blk)
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

      http.errback do
        cleanup.call do
          blk.call(DownloadError.new(:uri => uri))
        end
      end

      http.callback do
        cleanup.call do
          status = http.response_header.status
          if status == 200
            if self.sha1 == sha1.hexdigest
              blk.call(nil, file.path)
            else
              blk.call(DownloadError.new(:uri => uri, :reason => "SHA1 mismatch"))
            end
          else
            blk.call(DownloadError.new(:uri => uri, :status => status))
          end
        end
      end
    end
  end
end
