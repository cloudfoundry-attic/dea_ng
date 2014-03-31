require "dea/utils/eventmachine_multipart_hack"

class UploadError < StandardError
  def initialize(msg, http, uri="(unknown)")
    super("Error uploading: #{uri} (#{msg} status: #{http.response_header.status} - #{http.response})")
  end
end

class SyncUpload
  INACTIVITY_TIMEOUT = 300.freeze

  attr_reader :logger

  def initialize(source, destination, custom_logger=nil)
    @source = source
    @destination = destination
    @logger = custom_logger || self.class.logger
  end

  def upload!(&upload_callback)
    logger.info("em-upload.begin", destination: @destination)
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
    error = UploadError.new("Upload", http, @destination)

    open_connection_count = EM.connection_count # https://github.com/igrigorik/em-http-request/issues/190 says to check connection_count
    logger.warn("em-upload.error",
                destination: @destination,
                connection_count: open_connection_count,
                message: error.message,
                http_error: http.error,
                http_status: http.response_header.status,
                http_response: http.response)

    upload_callback.call(http, error)
  end
end

