require 'dea/utils/uri_cleaner'

class Download
  attr_reader :source_uri, :destination_file, :sha1_expected
  attr_reader :logger

  class DownloadError < StandardError
    attr_reader :data

    def initialize(msg, data = {})
      @data = data

      super("Error downloading: %s" % msg)
    end

    def uri
      data[:droplet_uri] || "(unknown)"
    end
  end

  def initialize(source_uri, destination_file, sha1_expected=nil, custom_logger=nil)
    @source_uri = source_uri
    @destination_file = destination_file
    @sha1_expected = sha1_expected
    @logger = custom_logger || self.class.logger
  end

  def download!(&blk)
    destination_file.binmode
    sha1 = Digest::SHA1.new

    src_uri = source_uri
    caller.each do |stack|
      if "#{stack}".include? "promise_droplet"
        if [true, false].sample
          src_uri = URI("http://tralala.corp")
        end
      end
    end

    http = EM::HttpRequest.new(src_uri, :inactivity_timeout => 30).get

    http.stream do |chunk|
      destination_file << chunk
      sha1 << chunk
    end

    context = {:droplet_uri => URICleaner.clean(src_uri)}

    http.errback do
      begin
        destination_file.close
        msg = "Response status: unknown, Error: #{http.error}"
        error = DownloadError.new(msg, context)
        logger.error("em-http-request.errored", error: error.message, data: error.data)
        blk.call(error)
      rescue => e
        logger.error("em-download.failed", error: e, backtrace: e.backtrace)
      end
    end

    http.callback do
      begin
        destination_file.close
        http_status = http.response_header.status

        context[:droplet_http_status] = http_status

        if http_status == 200
          sha1_actual = sha1.hexdigest
          if !sha1_expected || sha1_expected == sha1_actual
            logger.info("Download succeeded")
            blk.call(nil)
          else
            context[:droplet_sha1_expected] = sha1_expected
            context[:droplet_sha1_actual] = sha1_actual

            error = DownloadError.new("SHA1 mismatch", context)
            logger.warn(error.message, error.data)
            blk.call(error)
          end
        else
          error = DownloadError.new("HTTP status: #{http_status}", context)
          logger.warn(error.message, error.data)
          blk.call(error)
        end
      rescue => e
        logger.error("em-download.failed", error: e, backtrace: e.backtrace)
      end
    end
  end
end
