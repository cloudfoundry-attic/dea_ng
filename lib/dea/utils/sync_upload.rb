require "dea/utils/eventmachine_multipart_hack"
require "dea/utils/uri_cleaner"

class UploadError < StandardError
  def initialize(msg)
    super("Error uploading: (#{msg})")
  end
end

class SyncUpload
  INACTIVITY_TIMEOUT = 30.freeze

  attr_reader :logger

  def initialize(source, destination, custom_logger=nil)
    @source = source
    @destination = destination
    @logger = custom_logger || self.class.logger
  end

  def upload!(&upload_callback)
    logger.info("em-upload.begin", destination: URICleaner.clean(@destination))
    head = {EM::HttpClient::MULTIPART_HACK => {name: "upload[droplet]", filename: File.basename(@source)}}

    http = EM::HttpRequest.new(@destination, inactivity_timeout: INACTIVITY_TIMEOUT).post(
        head: head, file: @source, query: {async: "true"}
    )

    http.errback do
      handle_error(http, upload_callback)
    end

    http.callback do
      handle_http_response(http, upload_callback)
    end
  end

  private

  def handle_http_response(http, upload_callback)
    http_status = http.response_header.status

    if http_status < 300
      upload_callback.call(http, nil)
    else
      handle_error(http, upload_callback)
    end
  end

  def handle_error(http, upload_callback)
    if http.error
      error = UploadError.new("Upload failed - status #{http.response_header.status}; error: #{http.error}")
    else
      error = UploadError.new("Upload failed - status #{http.response_header.status}")
    end

    open_connection_count = EM.connection_count # https://github.com/igrigorik/em-http-request/issues/190 says to check connection_count
    logger.warn("em-upload.error",
                destination: URICleaner.clean(@destination),
                connection_count: open_connection_count,
                message: error.message,
                http_error: http.error,
                http_status: http.response_header.status,
                http_response: http.response)

    upload_callback.call(http, error)
  end
end

