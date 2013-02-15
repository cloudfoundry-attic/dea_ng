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

    subject { http.send_request(headers, body) }

    context "with multipart hack" do
      let(:headers) { {EM::HttpClient::MULTIPART_HACK => {:prepend => "PREPEND", :append => "APPEND"}} }
      let(:length) do
        File.size(tempfile) +
          headers[EM::HttpClient::MULTIPART_HACK][:prepend].length +
          headers[EM::HttpClient::MULTIPART_HACK][:prepend].length +
          ("\r\n".length * 2)
      end

      it "has the right headers including the content length" do
        conn.should_receive(:send_data).with("REQUEST_HEADERS{\"content-length\"=>#{length}}\r\n")
        subject
      end

      it "sends the correct multipart header" do
        conn.should_receive(:send_data).with("PREPEND\r\n")
        subject
      end

      it "adds the multipart footer to the file" do
        subject
        File.read(tempfile.path).should match /^BODY\r\nAPPEND$/
      end

      it "does not put the multipart header hack in the headers" do
        http.should_receive(:encode_headers).with({"content-length" => length})
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