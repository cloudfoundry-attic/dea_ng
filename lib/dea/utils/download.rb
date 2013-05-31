class Download
  attr_reader :uri, :blk, :destination_dir, :sha1_expected
  attr_reader :logger

  class DownloadError < StandardError
    attr_reader :data

    def initialize(msg, data = {})
      @data = data

      super("Error downloading: %s (%s)" % [uri, msg])
    end

    def uri
      data[:droplet_uri] || "(unknown)"
    end
  end

  def initialize(uri, destination_dir, sha1_expected=nil, custom_logger=nil)
    @uri = uri
    @destination_dir = destination_dir
    @sha1_expected = sha1_expected
    @logger = custom_logger || self.class.logger
  end

  def download!(&blk)
    FileUtils.mkdir_p(destination_dir)

    file = Tempfile.new("droplet", destination_dir, :mode => File::BINARY)
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
          sha1_actual   = sha1.hexdigest
          if !sha1_expected || sha1_expected == sha1_actual
            logger.info("Download succeeded")
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
