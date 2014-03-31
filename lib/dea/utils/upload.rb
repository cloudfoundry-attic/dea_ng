require "dea/utils/sync_upload"

class Upload
  POLLING_INTERVAL = 1.freeze
  POLLING_TIMEOUT_IN_SECOND = 300.freeze

  attr_reader :logger

  def initialize(source, destination, custom_logger=nil, polling_timeout_in_second=POLLING_TIMEOUT_IN_SECOND)
    @source = source
    @destination = destination
    @logger = custom_logger || self.class.logger
    @polling_timeout_in_second = polling_timeout_in_second
  end

  def upload!(&upload_callback)
    logger.info("em-upload.begin", destination: @destination)

    SyncUpload.new(@source, @destination, @logger).upload! do |http, error|
      if error
        upload_callback.call(error)
      else
        logger.debug("em-upload.completion.success", destination: @destination,
                    response: http.response,
                    class: http.response.class.name,
                    include: http.response.include?("url")
        )
        if http.response.include?("url")
          begin
            response = JSON.parse(http.response)
            polling_destination = URI.parse(response.fetch("metadata", {}).fetch("url", nil))
            @remaining_polling_time = @polling_timeout_in_second
            logger.debug("em-upload.completion.polling", destination: polling_destination)
            poll(polling_destination, &upload_callback) if polling_destination
          rescue JSON::ParserError
            logger.warn("em-upload.completion.parsing-error")
            upload_callback.call UploadError.new("invalid json", http, @destination)
          rescue URI::InvalidURIError => e
            logger.warn("em-upload.completion.invlid-polling-url", url: e)
            upload_callback.call UploadError.new("invalid URL #{e}", http, @destination)
          end
        else
          upload_callback.call(nil)
        end
      end
    end
  end

  private

  def poll(polling_destination, &upload_callback)
    logger.debug("em-upload.polling", polling_destination: polling_destination)
    http = EM::HttpRequest.new(polling_destination).get
    http.errback do
      logger.warn("em-upload.polling.handle_error")
      handle_error(http, polling_destination, upload_callback)
    end

    http.callback do
      logger.debug("em-upload.polling.handle_http_response")
      handle_http_response(http, polling_destination, upload_callback)
    end
  end

  def handle_http_response(http, polling_destination, upload_callback)
    if http.response_header.status < 300
      response = JSON.parse(http.response)

      case response.fetch("entity", {}).fetch("status", nil)
        when "finished"
          logger.debug("em-upload.polling.success.job-done")
          upload_callback.call nil
        when "failed"
          logger.warn("em-upload.polling.failed", response: http.response)
          upload_callback.call UploadError.new("Polling", http, polling_destination)
        else
          @remaining_polling_time -= POLLING_INTERVAL
          if @remaining_polling_time <= 0
            logger.warn("em-upload.polling.timing-out")
            upload_callback.call UploadError.new("Job took too long", http, polling_destination)
          else
            logger.debug("em-upload.polling.retry")
            EM.add_timer(POLLING_INTERVAL) { poll(polling_destination, &upload_callback) }
          end
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
                http_response: http.response)

    upload_callback.call(error)
  end
end

