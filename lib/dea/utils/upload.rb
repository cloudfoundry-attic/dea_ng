require "dea/utils/sync_upload"
require "dea/utils/uri_cleaner"

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
    logger.info("em-upload.begin", destination: URICleaner.clean(@destination))

    SyncUpload.new(@source, @destination, @logger).upload! do |http, error|
      if error
        upload_callback.call(error)
      else
        logger.debug("em-upload.completion.success", destination: URICleaner.clean(@destination),
                    response: http.response,
                    class: http.response.class.name,
                    include: http.response.include?("url")
        )
        if http.response.include?("url")
          begin
            response = JSON.parse(http.response)
            polling_destination = URI.parse(response.fetch("metadata", {}).fetch("url", nil))
            @remaining_polling_time = @polling_timeout_in_second
            logger.debug("em-upload.completion.polling", destination: URICleaner.clean(polling_destination))
            poll(polling_destination, &upload_callback) if polling_destination
          rescue JSON::ParserError
            logger.warn("em-upload.completion.parsing-error")
            upload_callback.call UploadError.new("invalid json")
          rescue URI::InvalidURIError => e
            logger.warn("em-upload.completion.invlid-polling-url", url: e)
            upload_callback.call UploadError.new("invalid URL #{e}")
          end
        else
          upload_callback.call(nil)
        end
      end
    end
  end

  def handle_error(http, polling_destination, upload_callback)
    if http.error
      error = UploadError.new("Polling failed - status #{http.response_header.status}; error: #{http.error}")
    else
      error = UploadError.new("Polling failed - status #{http.response_header.status}")
    end

    open_connection_count = EM.connection_count # https://github.com/igrigorik/em-http-request/issues/190 says to check connection_count
    logger.warn("em-upload.error",
      destination: URICleaner.clean(@destination),
      connection_count: open_connection_count,
      message: error.message,
      http_error: http.error,
      http_status: http.response_header.status,
      http_response: http.response)

    if http.error == Errno::ETIMEDOUT
      retry_if_time_left(polling_destination, upload_callback)
    else
      upload_callback.call(error)
    end
  end

  private

  def retry_if_time_left(polling_destination, callback)
    @remaining_polling_time -= POLLING_INTERVAL
    if @remaining_polling_time <= 0
      logger.warn("em-upload.polling.timing-out")
      callback.call UploadError.new("Job took too long")
    else
      logger.debug("em-upload.polling.retry")
      EM.add_timer(POLLING_INTERVAL) { poll(polling_destination, &callback) }
    end
  end

  def poll(polling_destination, &upload_callback)
    logger.debug("em-upload.polling", polling_destination: URICleaner.clean(polling_destination))
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
          upload_callback.call UploadError.new("Staging upload failed.")
        else
          retry_if_time_left(polling_destination, upload_callback)
      end
    else
      handle_error(http, polling_destination, upload_callback)
    end
  rescue JSON::ParserError
    logger.warn("em-upload.polling.invalid_json_response", response: http.response)
    upload_callback.call UploadError.new("polling invalid json")
  end
end
