# coding: UTF-8

require "spec_helper"
require "dea/staging"
require "em-http"

describe Dea::Staging do
  include_context "tmpdir"

  let(:bootstrap) do
    mock = mock("bootstrap")
    mock.stub(:config) { {"base_dir" => ".", "staging" => {}} }
    mock
  end
  let(:logger) do
    mock = mock("logger")
    mock.stub(:debug2)
    mock.stub(:info)
    mock.stub(:warn)
    mock
  end
  let(:staging) { Dea::Staging.new(bootstrap, valid_staging_attributes) }
  let(:workspace_dir) { tmpdir }

  before do
    staging.stub(:workspace_dir) { workspace_dir }
    staging.stub(:staged_droplet_path) { __FILE__ }
    staging.stub(:logger) { logger }
  end

  describe '#start' do
    it 'should be delivered' do

    end
  end

  describe '#promise_stage' do

  end

  describe '#promise_unpack_app' do
  end

  describe '#promise_pack_app' do
  end

  describe '#promise_app_download' do
    subject do
      promise = staging.promise_app_download
      promise.run
      promise
    end

    context 'when there is an error' do
      before { staging.stub(:download_app).and_yield("This is an error") }
      its(:result) { should == [:fail, "This is an error"] }
    end

    context 'when there is no error' do
      before { staging.stub(:download_app).and_yield(nil) }
      its(:result) { should == [:deliver, nil]}
    end
  end

  describe '#promise_app_upload' do
    subject do
      promise = staging.promise_app_upload
      promise.run
      promise
    end

    context 'when there is an error' do
      before { staging.stub(:upload_app).and_yield("This is an error") }
      its(:result) { should == [:fail, "This is an error"] }
    end

    context 'when there is no error' do
      before { staging.stub(:upload_app).and_yield(nil) }
      its(:result) { should == [:deliver, nil]}
    end
  end

  describe '#promise_copy_out' do
    subject do
      promise = staging.promise_copy_out
      promise.run
      promise
    end

    it 'should print out some info' do
      logger.should_receive(:info).with(anything)
      subject
    end

    it "should send copying out request" do
      staging.should_receive(:copy_out_request).with(Dea::Staging::WARDEN_STAGED_DROPLET, /.{5,}/)
      subject
    end
  end

  describe '#upload_app' do
  end

  describe '#download_app' do
  end

  describe '#create_multipart_file' do
    let(:source) { __FILE__ }
    let(:boundary) { subject[0] }

    subject { staging.create_multipart_file(source) }


    it 'should have a random boundary' do
      first, _ = subject
      first.should =~ /.{10,}/

      second, _ = staging.create_multipart_file(source)
      second.should_not == first

      third, _ = staging.create_multipart_file(source)
      third.should_not == first
      third.should_not == second
    end

    context "the contents of the file" do
      let(:files) { Dir[workspace_dir + "/*"] }
      let(:file) { File.read(files[0]) }

      before { subject }

      it 'should only create one file' do
        files.length.should == 1
      end

      it 'should have the correct header' do
        file.should start_with <<-HEADER
--#{boundary}
Content-Disposition: form-data; name="upload[droplet]"; filename="droplet.tgz"
Content-Type: application/octet-stream

HEADER
      end

      it 'should have the correct body' do
        file.should include File.read(__FILE__)
      end

      it 'should have the correct footer' do
        file.should end_with "\r\n--#{boundary}--"
      end
    end
  end

  def em_start(code = 200)
    body = ""

    start_http_server(12346) do |connection, _|
      connection.send_data("HTTP/1.1 #{code} OK\r\n")
      connection.send_data("Content-Length: #{body.length}\r\n")
      connection.send_data("\r\n")
      connection.send_data(body)
      connection.send_data("\r\n")

      body
    end
  end

  describe '#put_app' do
    it "should call callback without error" do
      em do
        em_start

        staging.put_app do |err, path|
          err.should be nil
          path.should end_with "spec/dea/staging_spec.rb"

          done
        end
      end
    end

    it "should call callback with a HTTP 400+ error" do
      em do
        em_start(422)

        staging.put_app do |err, _|
          err.should be_a Dea::Staging::UploadError

          done
        end
      end
    end

    xit "should call the error callback when a connection error occurs" do
      EM.stub(:bind_connect).and_raise(EM::ConnectionError)

      staging.put_app do |err, _|
        err.should be_a Dea::Staging::UploadError
        err.data.should == {upload_uri: "http://127.0.0.1:12346/upload"}

        done
      end
    end
  end

  describe '#get_app' do
    it "should call callback without error" do
      em do
        em_start

        staging.get_app do |err, path|
          err.should be nil
          path.should =~ /#{workspace_dir}/

          done
        end
      end
    end

    it "should call callback with a HTTP 400+ error" do
      em do
        em_start(422)

        staging.get_app do |err, _|
          err.should be_a Dea::Staging::DownloadError
          err.data.should == {
            download_uri: "http://127.0.0.1:12346/download",
            droplet_http_status: 422
          }

          done
        end
      end
    end
  end
end
