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
      prepend = multipart[:prepend] + EventMachine::HttpClient::CRLF
      append = multipart[:append]

      # We append as #stream_file_data closes the connection
      system "echo '#{EventMachine::HttpClient::CRLF}#{append}' >> #{file}"

      head['content-length'] = File.size(file) + prepend.length

      request_header ||= encode_request(@req.method, @req.uri, @req.query, @conn.connopts.proxy)
      request_header << encode_headers(head)
      request_header << EventMachine::HttpClient::CRLF

      @conn.send_data request_header
      @conn.send_data prepend
      @conn.stream_file_data file, :http_chunks => false
    else
      send_request_without_multipart(head, body)
    end
  end
  alias_method_chain :send_request, :multipart
end