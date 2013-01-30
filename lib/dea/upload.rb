class Upload
  BUFFER_SIZE = (1024 * 1024).freeze

  class UploadError < StandardError
    attr_reader :data

    def initialize(msg, data = {})
      @data = data
      uri = data[:uri] || "(unknown)"
      super("<staging> Error uploading: %s (%s)" % [uri, msg])
    end
  end

  def initialize(source, destination)
    @source = source
    @destination = destination
  end

  def upload!(&blk)
    multipart_file_path = create_multipart_file(@source)

    http = EM::HttpRequest.new(@destination).post(
        head: {"Content-Type" => "multipart/form-data; boundary=#{boundary}"},
        file: multipart_file_path
    )

    context = { :upload_uri => @destination }

    http.errback do
      error = UploadError.new("<staging> Response status: unknown", context)
      blk.call(error)
    end

    http.callback do
      http_status = http.response_header.status
      if http_status == 200
        blk.call(nil)
      else
        error = UploadError.new("HTTP status: #{http_status}", context)
        blk.call(error)
      end
    end
  end

  private

  def create_multipart_file(source)
    multipart_file = Tempfile.new("multipart", File.dirname(source))

    File.open(source, "r") do |source_file|
      File.open(multipart_file.path, "a") do |dest_file|
        dest_file.write("--#{boundary}\n")
        dest_file.write(multipart_header)

        while (record = source_file.read(BUFFER_SIZE))
          dest_file.write(record)
        end

        dest_file.write("\r\n--#{boundary}--")
      end
    end

    multipart_file.path
  end

  def boundary
    @boundry ||= "mutipart-boundary-#{SecureRandom.uuid}"
  end

  def multipart_header
    <<-DATA
Content-Disposition: form-data; name="upload[droplet]"; filename="droplet.tgz"
Content-Type: application/octet-stream

    DATA
  end
end