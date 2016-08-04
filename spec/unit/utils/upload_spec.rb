require 'spec_helper'
require 'dea/utils/upload'

describe Upload do
  let(:file_to_upload) do
    file_to_upload = Tempfile.new("file_to_upload")
    file_to_upload << "This is the file contents"
    file_to_upload.close
    file_to_upload
  end

  let(:to_uri) { URI("http://127.0.0.1:12345/") }

  let(:polling_timeout_in_second) { 3 }

  let(:logger) { nil }

  subject { Upload.new(file_to_upload.path, to_uri, logger, polling_timeout_in_second) }

  describe "#upload!" do
    let(:request) { double(:request, method: 'delete').as_null_object }
    let(:http) { double(:http, req: request).as_null_object }
    let(:uploaded_contents) { "" }
    let(:status) { "running" }
    let(:job_url) { "http://127.0.0.1:12345/v2/jobs/123" }
    let(:job_string) { JSON.dump(job_json) }

    let(:job_json) do
      {
          metadata: {guid: 123, created_at: Time.now.to_s, url: job_url},
          entity: {guid: 123, status: status}
      }
    end

    def create_response(connection, message, code = 200)
      connection.send_data("HTTP/1.1 #{code}\r\n")
      connection.send_data("Content-Length: #{message.length}\r\n")
      connection.send_data("\r\n")
      connection.send_data(message)
      connection.send_data("\r\n")
    end

    around do |example|
      with_event_machine { example.call }
    end

    it "requests an async upload of the droplet" do
      stub_request(:post, "http://127.0.0.1:12345/").with(query: {async: "true"})
      ran = false
      subject.upload! { ran = true }
      expect(ran).to be false
      done
    end

    it "creates the correct multipart request (with a high inactivity timeout which should be removed when everything is aysnc)" do
      expect(EM::HttpRequest).to receive(:new).with(to_uri, inactivity_timeout: 30).and_return(http)
      expect(http).to receive(:post).with(
                          head: {'x-cf-multipart' => {name: "upload[droplet]", filename: anything}},
                          file: file_to_upload.path,
                          query: {async: "true"}
                      )

      subject.upload! {}

      done
    end

    context "when sync and successfully" do
      before do
        start_http_server(12345) do |connection, data|
          uploaded_contents << data
          create_response(connection, "")
        end
      end

      it "uploads a file" do
        subject.upload! do |error|
          expect(error).to be_nil
          expect(uploaded_contents).to match(/.*multipart-boundary-.*Content-Disposition.*This is the file contents.*multipart-boundary-.*/m)
          done
        end
      end
    end

    context "when async" do
      context "and the polling URL is invalid" do
        let(:job_url) { "I am not a url!" }
        before do
          start_http_server(12345) do |connection, data|
            create_response(connection, job_string)
          end
        end

        it "should report an error" do
          subject.upload! do |error|
            expect(error).to be_a(UploadError)
            expect(error.message).to match /invalid url/i
            done
          end
        end
      end

      context 'and it cannot reach the CC' do
        let(:job_url) {'http://localhost:12346'}
        before do
          start_http_server(12345) do |connection, data|
            create_response(connection, job_string)
          end
        end

        it 'should populate the error message correctly' do
          subject.upload! do |error|
            expect(error.message).to include "Polling failed - status 0; error: Errno::ECONNREFUSED"
            done
          end
        end
      end

      context "and the polling URL is valid and the polling returns a 2xx" do
        let(:finished_json_string) { JSON.dump(job_json.merge(entity: {guid: 123, status: "finished"})) }

        context "and the polling is successful" do
          before do
            @request_timestamps ||= []
            counter = 0
            start_http_server(12345) do |connection, _|
              @request_timestamps << Time.now
              create_response(connection, counter < 2 ? job_string : finished_json_string)
              counter += 1
            end
          end

          it "should poll the cloud controller until done" do
            subject.upload! do |error|
              expect(error).to be_nil
              done
            end
          end

          it "should poll around every second" do
            subject.upload! do
              expect(@request_timestamps[-1] - @request_timestamps[-2]).to be >= 1.0
              done
            end
          end
        end

        context "and the polling never finishes" do
          let(:processing_json_string) { JSON.dump(job_json.merge(entity: {guid: 123, status: "processing"})) }

          before do
            @request_timestamps ||= []
            counter = 0
            start_http_server(12345) do |connection, data|
              @request_timestamps << Time.now
              create_response(connection, counter < 2 ? job_string : processing_json_string)
              counter += 1
            end
          end

          it "should poll for a configured period of time before giving up" do
            subject.upload! do |error|
              expect(@request_timestamps.size).to be <= 4
              done
            end
          end

          it "should return an error" do
            subject.upload! do |error|
              expect(error.message).to include "Error uploading: (Job took too long"
              done
            end
          end
        end

        context "and the polling returns a failed upload" do
          let(:error_json_string) { JSON.dump(job_json.merge(entity: {guid: 123, status: "failed"})) }

          before do
            counter = 0
            start_http_server(12345) do |connection, data|
              create_response(connection, counter < 2 ? job_string : error_json_string)
              counter += 1
            end
          end

          it "should poll the cloud controller until failed and returns failure information" do
            subject.upload! do |error|
              expect(error.message).to include "Error uploading: (Staging upload failed.)"
              done
            end
          end
        end

        context "and the upload returns invalid json" do
          before do
            start_http_server(12345) do |connection, _|
              create_response(connection, "invalid_json_with_url")
            end
          end

          it "returns a error" do
            subject.upload! do |error|
              expect(error).to be_a(UploadError)
              expect(error.message).to match /invalid json/i
              done
            end
          end
        end

        context "and the polling returns invalid json" do
          before do
            counter = 0
            start_http_server(12345) do |connection, _|
              if counter == 0
                create_response(connection, job_string)
              else
                create_response(connection, "invalid_json_after_polling")
              end
              counter += 1
            end
          end

          it "returns a error" do
            subject.upload! do |error|
              expect(error).to be_a(UploadError)
              expect(error.message).to match /polling invalid json/i
              done
            end
          end
        end
      end

      context "and the polling URL is valid and the polling does not return a 2xx" do
        context "and the polling response from the cc is a 5xx" do
          before do
            counter = 0
            start_http_server(12345) do |connection, data|
              create_response(connection, job_string, counter > 1 ? 500 : 200)
              counter += 1
            end
          end

          it "should poll the cloud controller until errback-ed and returns failure information" do
            subject.upload! do |error|
              expect(error.message).to include "Error uploading: (Polling failed - status 500)"
              done
            end
          end

        end

        context "and the polling response from the cc is a 4xx" do
          before do
            counter = 0
            start_http_server(12345) do |connection, data|
              if counter < 2
                create_response(connection, job_string)
              else
                create_response(connection, "Client Error", 400)
              end
              counter += 1
            end
          end

          it "should poll the cloud controller until failed and returns failure information" do
            subject.upload! do |error|
              expect(error.message).not_to be_nil
              expect(error.message).to eq "Error uploading: (Polling failed - status 400)"
              done
            end
          end
        end
      end

      describe "#handle_error" do
        context "when a Errno::ETIMEDOUT occured" do
          it "does not call the upload callbback" do
            http = double(:http, error: Errno::ETIMEDOUT).as_null_object
            upload_callback = double(:upload_callback)
            subject.instance_variable_set(:@remaining_polling_time, 120)
            expect(upload_callback).not_to receive(:call)
            expect(subject).to receive(:retry_if_time_left)
            subject.handle_error(http, "", upload_callback)
            done
          end
        end

        context "when another type of error ocurred" do
          it "calls the upload callback with that error" do
            http = double(:http).as_null_object
            upload_callback = double(:upload_callback)
            expect(upload_callback).to receive(:call).with(kind_of(UploadError))
            subject.handle_error(http, "", upload_callback)
            done
          end
        end
      end
    end

    context "when there is no server running" do
      it "calls the block with the exception" do
        subject.upload! do |error|
          expect(error).to be_a(UploadError)
          expect(error.message).to include "Error uploading: (Upload failed"
          expect(error.message).to include "error: Errno::ECONNREFUSED"
          done
        end
      end
    end

    context "when you get a 500" do
      before do
        start_http_server(12345) do |connection, data|
          create_response(connection, "", 500)
        end
      end

      it "calls the block with the exception" do
        subject.upload! do |error|
          expect(error).to be_a(UploadError)
          expect(error.message).to match %r{Error uploading: \(Upload failed - status 500}
          done
        end
      end
    end
  end
end
