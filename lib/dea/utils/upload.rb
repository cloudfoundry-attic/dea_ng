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
    logger.info("em-upload.begin", destination: @destination)

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
      begin
        error = UploadError.new("Response status: unknown", @destination)

        # Occasionally getting into this errback when we don't expect to...
        # https://github.com/igrigorik/em-http-request/issues/190 says to check connection_count
        open_connection_count = EM.connection_count
        logger.warn("em-upload.error",
                    destination: @destination,
                    connection_count: open_connection_count,
                    message: error.message,
                    http_error: http.error,
                    http_status: http.response_header.status,
                    http_response: http.response
        )

        upload_callback.call(error)
      rescue => e
        logger.error "em-upload.failed", error: e, backtrace: e.backtrace
      end
    end

    http.callback do
      begin
        http_status = http.response_header.status

        if http_status == 200
          logger.info("em-upload.completion.success", destination: @destination)
          upload_callback.call(nil)
        else
          error = UploadError.new("HTTP status: #{http_status} - #{http.response}", @destination)
          logger.warn("em-upload.completion.failure", destination: @destination, message: error.message)
          upload_callback.call(error)
        end
      rescue => e
        logger.error "em-upload.failed", error: e, backtrace: e.backtrace
      end
    end
  end
end
