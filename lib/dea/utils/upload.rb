require "dea/utils/eventmachine_multipart_hack"

class Upload
  attr_reader :logger

  class UploadError < StandardError
    def initialize(msg, uri="(unknown)")
      super("Error uploading: %s (%s)" % [uri, msg])
    end
  end

  def initialize(source, destination, custom_logger=nil)
    @source = source
    @destination = destination
    @logger = custom_logger || self.class.logger
  end

  def upload!(&upload_callback)
    http = EM::HttpRequest.new(@destination).post(
      head: {
        EM::HttpClient::MULTIPART_HACK => {
          :name => "upload[droplet]",
          :filename => File.basename(@source)
        }
      },
      file: @source
    )

    http.errback do
      error = UploadError.new("Response status: unknown", @destination)
      logger.warn(error.message)
      upload_callback.call(error)
    end

    http.callback do
      http_status = http.response_header.status

      if http_status == 200
        logger.info("Upload succeeded")
        upload_callback.call(nil)
      else
        error = UploadError.new("HTTP status: #{http_status} - #{http.response}", @destination)
        logger.warn(error.message)
        upload_callback.call(error)
      end
    end
  end
end
