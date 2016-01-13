require 'spec_helper'
require 'dea/utils/eventmachine_multipart_hack'

describe EventMachine::HttpClient do
  describe "version (make certain you see if this hack is still needed)" do
    it 'matches the current version' do
      expect(EM::HttpRequest::VERSION).to eq "1.1.3"
    end
  end

  describe "#send_request" do
    let(:body) { "BODY" }
    let(:conn) do
      conn = double("connection")
      allow(conn).to receive(:send_data)
      allow(conn).to receive(:stream_file_data)
      allow(conn).to receive_message_chain(:connopts, :proxy) { "CONN_OPTS" }
      conn
    end
    let(:options) do
      options = double("options")
      allow(options).to receive(:file).and_return(tempfile.path)
      allow(options).to receive(:method).and_return("POST")
      allow(options).to receive(:uri).and_return("POST")
      allow(options).to receive(:query).and_return("QUERY")
      options
    end
    let(:http) do
      http = EventMachine::HttpClient.new(conn, options)
      allow(http).to receive(:encode_request).and_return("REQUEST_HEADERS")
      allow(http).to receive(:encode_headers) { |head| head.to_s }
      http
    end
    let!(:tempfile) do
      file = Tempfile.new("tempfile")
      file.write(body)
      file.rewind
      file
    end

    before { allow(SecureRandom).to receive(:uuid).and_return("UUID") }

    subject { http.send_request(headers, body) }

    context "with multipart hack" do
      let(:headers) do
        {
          "FOO" => "BAR",
          EM::HttpClient::MULTIPART_HACK => {
            :name => "foo",
            :filename => "foo.bar",
            :content_type => "application/octet-stream"
          }
        }
      end

      let(:expected_header) {
        [
          "--multipart-boundary-UUID",
          "Content-Disposition: form-data; name=\"foo\"; filename=\"foo.bar\"",
          "Content-Type: application/octet-stream",
          "",
          ""
        ].join("\r\n")
      }

      it "has the right http headers including the content length" do
        expected_length = expected_header.length + body.length + "\r\n--multipart-boundary-UUID--\n".length
        allow(conn).to receive(:send_data).with("REQUEST_HEADERS{\"FOO\"=>\"BAR\", \"content-type\"=>\"multipart/form-data; boundary=multipart-boundary-UUID\", \"content-length\"=>#{expected_length}}\r\n")
        subject
      end

      it "sends the correct multipart header (the number of new lines is really important)" do
        allow(conn).to receive(:send_data).with(expected_header)
        subject
      end

      it "streams the file" do
        allow(conn).to receive(:stream_file_data).with(tempfile.path, :http_chunks => false)
        subject
      end

      it "adds the multipart footer to the file" do
        subject
        expect(File.read(tempfile.path)).to eq("#{body}\r\n--multipart-boundary-UUID--\n")
      end
    end

    context "without multipart hack" do
      let(:headers) { {"foo" => "bar"} }

      it "calls the original send_request" do
        allow(http).to receive(:send_request_without_multipart).with(headers, body)
        subject
      end
    end
  end
end
