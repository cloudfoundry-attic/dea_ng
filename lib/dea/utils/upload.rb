require "dea/utils/sync_upload"

class Upload
  POLLING_INTERVAL = 1.freeze

  attr_reader :logger

  def initialize(source, destination, custom_logger=nil)
    @source = source
    @destination = destination
    @logger = custom_logger || self.class.logger
  end

  def upload!(&upload_callback)
    logger.info("em-upload.begin", destination: @destination)

    SyncUpload.new(@source, @destination, @logger).upload! do |http, error|
      if error
        upload_callback.call(error)
      else
        logger.info("em-upload.completion.success", destination: @destination)
        if http.response.include?("url")
          begin
            response = JSON.parse(http.response)
            polling_destination = response.fetch("metadata", {}).fetch("url", nil)
            poll(polling_destination, &upload_callback) if polling_destination
          rescue JSON::ParserError
            upload_callback.call UploadError.new("invalid json", http, @destination)
          end
        else
          upload_callback.call(nil)
        end
      end
    end
  end

  private

  def poll(polling_destination, &upload_callback)
    http = EM::HttpRequest.new(polling_destination).get

    http.errback do
      handle_error(http, polling_destination, upload_callback)
    end

    http.callback do
      handle_http_response(http, polling_destination, upload_callback)
    end
  end

  def handle_http_response(http, polling_destination, upload_callback)
    if http.response_header.status < 300
      response = JSON.parse(http.response)

      case response.fetch("entity", {}).fetch("status", nil)
        when "finished"
          upload_callback.call nil
        when "failed"
          upload_callback.call UploadError.new("Polling", http, polling_destination)
        else
          EM.add_timer(POLLING_INTERVAL) { poll(polling_destination, &upload_callback) }
      end
    else
      handle_error(http, polling_destination, upload_callback)
    end
  rescue JSON::ParserError
    upload_callback.call UploadError.new("polling invalid json", http, @destination)
  end

  def handle_error(http, polling_destination, upload_callback)
    error = UploadError.new("Polling", http, polling_destination)

    open_connection_count = EM.connection_count # https://github.com/igrigorik/em-http-request/issues/190 says to check connection_count
    logger.warn("em-upload.error",
                destination: @destination,
                connection_count: open_connection_count,
                message: error.message,
                http_error: http.error,
                http_status: http.response_header.status,
                http_response: http.response
    )

    upload_callback.call(error)
  end
end

