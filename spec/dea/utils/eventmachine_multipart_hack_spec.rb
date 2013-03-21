require 'spec_helper'
require 'dea/utils/eventmachine_multipart_hack'

describe EventMachine::HttpClient do
  describe "version (make certain you see if this hack is still needed)" do
    it { EM::HttpRequest::VERSION.should eq "1.0.3" }
  end

  describe "#send_request" do
    let(:body) { "BODY" }
    let(:conn) do
      conn = mock("connection")
      conn.stub(:send_data)
      conn.stub(:stream_file_data)
      conn.stub_chain(:connopts, :proxy) { "CONN_OPTS" }
      conn
    end
    let(:options) do
      options = mock("options")
      options.stub(:file) { tempfile.path }
      options.stub(:method) { "POST" }
      options.stub(:uri) { "POST" }
      options.stub(:query) { "QUERY" }
      options
    end
    let(:http) do
      http = EventMachine::HttpClient.new(conn, options)
      http.stub(:encode_request) { "REQUEST_HEADERS" }
      http.stub(:encode_headers) { |head| head.to_s }
      http
    end
    let!(:tempfile) do
      file = Tempfile.new("tempfile")
      file.write("BODY")
      file.rewind
      file
    end

    before { SecureRandom.stub(:uuid) { "UUID" } }

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

      let(:length) { 165 }

      it "sends the correct multipart header (the number of new lines is really important)" do
        expected_header = [
          "--multipart-boundary-UUID",
          "Content-Disposition: form-data; name=\"foo\"; filename=\"foo.bar\"",
          "Content-Type: application/octet-stream",
          "",
          ""
        ].join("\r\n")

        conn.should_receive(:send_data).with(expected_header)
        subject
      end

      it "adds the multipart footer to the file" do
        subject
        File.read(tempfile.path).should eq("#{body}\r\n--multipart-boundary-UUID--\n")
      end

      it "streams the file" do
        conn.should_receive(:stream_file_data).with(tempfile.path, :http_chunks => false)
        subject
      end

      it "has the right headers including the content length" do
        conn.should_receive(:send_data).with("REQUEST_HEADERS{\"FOO\"=>\"BAR\", \"content-type\"=>\"multipart/form-data; boundary=multipart-boundary-UUID\", \"content-length\"=>#{length}}\r\n")
        subject
      end

      it "does not put the multipart header hack in the headers" do
        http.should_receive(:encode_headers).with(
          "FOO" => "BAR",
          "content-type" => "multipart/form-data; boundary=multipart-boundary-UUID",
          "content-length" => length
        )
        subject
      end
    end

    context "without multipart hack" do
      let(:headers) { {"foo" => "bar"} }

      it "calls the original send_request" do
        http.should_receive(:send_request_without_multipart).with(headers, body)
        subject
      end
    end
  end
end