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
      multipart_header = make_multipart_header(multipart[:name], multipart[:filename])

      # We append as #stream_file_data closes the connection
      if VCAP::WINDOWS
        File.open(file, 'ab') do |f|
          f.puts("#{EventMachine::HttpClient::CRLF}#{multipart_footer}")
        end
      else
        system "echo '#{EventMachine::HttpClient::CRLF}#{multipart_footer}' >> #{file}"
      end

      @conn.send_data http_header(file, head, multipart_header)
      @conn.send_data multipart_header
      @conn.stream_file_data file, :http_chunks => false
    else
      send_request_without_multipart(head, body)
    end
  end

  alias_method_chain :send_request, :multipart

  private

  def make_multipart_header(name, filename)
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

  def http_header(file, head, multipart_header)
    [
      encode_request(@req.method, @req.uri, @req.query, @conn.connopts.proxy),
      encode_headers(head.merge(
        "content-type" => "multipart/form-data; boundary=#{boundary}",
        "content-length" => File.size(file) + multipart_header.length
      )),
      EventMachine::HttpClient::CRLF
    ].join('')
  end
end
