require 'eventmachine'
require 'em-http'
require 'em-http/version'
require 'backports'

raise "Upgrade hack if necessary" if EM::HttpRequest::VERSION != "1.0.3"

EventMachine::HttpClient::MULTIPART_HACK = "x-cf-multipart".freeze

EventMachine::HttpClient.class_eval do
  def send_request_with_multipart(head, body)
    if (multipart = head.delete(EventMachine::HttpClient::MULTIPART_HACK))
      file = @req.file
      header = multipart_header(multipart[:name], multipart[:filename])

      # We append as #stream_file_data closes the connection
      system "echo '#{EventMachine::HttpClient::CRLF}#{multipart_footer}' >> #{file}"

      @conn.send_data request_header(file, head, header)
      @conn.send_data header
      @conn.stream_file_data file, :http_chunks => false
    else
      send_request_without_multipart(head, body)
    end
  end
  alias_method_chain :send_request, :multipart


  private

  def multipart_header(name, filename)
    # TWO blank lines are needed at the end according to http://www.w3.org/Protocols/rfc1341/7_2_Multipart.html
    [
      "--#{boundary}",
      "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"",
      "Content-Type: application/octet-stream",
      "",
      ""
    ].join(EventMachine::HttpClient::CRLF)
  end

  def multipart_footer
    "--#{boundary}--"
  end

  def boundary
    @boundary ||= "multipart-boundary-#{SecureRandom.uuid}"
  end

  def request_header(file, head, header)
    head["content-type"] = "multipart/form-data; boundary=#{boundary}"
    head["content-length"] = File.size(file) + header.length

    request_header ||= encode_request(@req.method, @req.uri, @req.query, @conn.connopts.proxy)
    request_header << encode_headers(head)
    request_header << EventMachine::HttpClient::CRLF
    request_header
  end
end