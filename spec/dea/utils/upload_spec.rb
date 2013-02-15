require 'spec_helper'
require 'dea/utils/upload'

describe Upload do
  let(:file_to_upload) do
    file_to_upload = Tempfile.new("file_to_upload")
    file_to_upload << "This is the file contents"
    file_to_upload.close
    file_to_upload
  end

  subject { Upload.new(file_to_upload.path, "http://127.0.0.1:12345/") }

  before do
    SecureRandom.stub(:uuid) { "UUID" }
  end

  describe "#upload!" do
    around do |example|
      em { example.call }
    end

    context "when uploading successfully" do
      it "uploads a file" do
        uploaded_contents = ""
        start_http_server(12345) do |connection, data|
          uploaded_contents << data
          connection.send_data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        end

        subject.upload! do |error|
          error.should be_nil
          uploaded_contents.should match(/.*multipart-boundary-UUID.*Content-Disposition.*This is the file contents.*multipart-boundary-UUID.*/m)
          done
        end
      end
    end

    context "when there is no server running" do
      it "calls the block with the exception" do
        subject.upload! do |error|
          error.should be_a(Upload::UploadError)
          error.message.should == "<staging> Error uploading: http://127.0.0.1:12345/ (Response status: unknown)"
          done
        end
      end
    end

    context "when you get a 500" do
      it "calls the block with the exception" do
        start_http_server(12345) do |connection, data|
          body = ""
          connection.send_data("HTTP/1.1 500\r\n")
          connection.send_data("Content-Length: #{body.length}\r\n")
          connection.send_data("\r\n")
          connection.send_data(body)
          connection.send_data("\r\n")
        end

        subject.upload! do |error|
          error.should be_a(Upload::UploadError)
          error.message.should == "<staging> Error uploading: http://127.0.0.1:12345/ (HTTP status: 500)"
          done
        end
      end
    end
  end

  describe "#multipart_header" do
    it "returns correct header" do
      subject.multipart_header.should eq <<-DATA
--multipart-boundary-UUID
Content-Disposition: form-data; name="upload[droplet]"; filename="droplet.tgz"
Content-Type: application/octet-stream

      DATA
    end
  end

  describe "#multipart_footer" do
    it "returns correct footer" do
      subject.multipart_footer.should eq "--multipart-boundary-UUID--"
    end
  end
end
