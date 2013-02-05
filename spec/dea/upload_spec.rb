require 'spec_helper'
require 'dea/upload'

describe Upload do
  around do |example|
    em do
      example.call
    end
  end

  let(:file_to_upload) do
    file_to_upload = Tempfile.new("file_to_upload")
    file_to_upload << "This is the file contents"
    file_to_upload.close
    file_to_upload
  end

  it "uploads a file" do
    uploaded_contents = ""
    start_http_server(12345) do |connection, data|
      body = ""
      uploaded_contents << data
      connection.send_data("HTTP/1.1 200 OK\r\n")
      connection.send_data("Content-Length: #{body.length}\r\n")
      connection.send_data("\r\n")
      connection.send_data(body)
      connection.send_data("\r\n")
    end


    upload = Upload.new(file_to_upload.path, "http://127.0.0.1:12345/")
    upload.upload! do |error|
      error.should be_nil

      uploaded_contents.should match(/#{Regexp.escape("#{upload.send(:boundary)}\n#{upload.send(:multipart_header)}")}This is the file contents/)
      done
    end
  end

  context "when there is no server running" do
    it "calls the block with the exception" do
      upload = Upload.new(file_to_upload.path, "http://127.0.0.1:12345/")
      upload.upload! do |error|
        error.should be_a(Upload::UploadError)
        done
      end
    end
  end

  context "when you get a 500" do
    it "calls the block with the exeception" do
      start_http_server(12345) do |connection, data|
        body = ""
        connection.send_data("HTTP/1.1 500\r\n")
        connection.send_data("Content-Length: #{body.length}\r\n")
        connection.send_data("\r\n")
        connection.send_data(body)
        connection.send_data("\r\n")
      end

      upload = Upload.new(file_to_upload.path, "http://127.0.0.1:12345/")
      upload.upload! do |error|
        error.should be_a(Upload::UploadError)
        done
      end
    end
  end
end