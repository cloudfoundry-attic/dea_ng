require "dea/utils/eventmachine_multipart_hack"

class Upload
  attr_reader :logger

  class UploadError < StandardError
    attr_reader :data

    def initialize(msg, uri="(unknown)")
      @data = { :message => msg, :uri => uri }
      super("upload.failed")
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
      logger.warn(error.message, error.data)
      upload_callback.call(error)
    end

    http.callback do
      http_status = http.response_header.status

      if http_status == 200
        logger.info("upload.succeeded", :source => @source)
        upload_callback.call(nil)
      else
        error = UploadError.new("HTTP status: #{http_status} - #{http.response}", @destination)
        logger.warn(error.message)
        upload_callback.call(error, error.data)
      end
    end
  end
end
