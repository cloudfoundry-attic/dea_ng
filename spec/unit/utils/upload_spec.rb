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
          uploaded_contents.should match(/.*multipart-boundary-.*Content-Disposition.*This is the file contents.*multipart-boundary-.*/m)
          done
        end
      end
    end

    context "when there is no server running" do
      it "calls the block with the exception" do
        subject.upload! do |error|
          error.should be_a(Upload::UploadError)
          error.message.should == "upload.failed"
          error.data[:message].should == "Response status: unknown"
          error.data[:uri].should == "http://127.0.0.1:12345/"
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
          error.message.should == "upload.failed"
          error.data[:message].should =~ /HTTP status: 500/
          error.data[:uri].should == "http://127.0.0.1:12345/"
          done
        end
      end
    end
  end
end
