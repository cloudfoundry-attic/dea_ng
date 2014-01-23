require "spec_helper"
require "dea/utils/download"

describe Download do
  around do |example|
    em { example.call }
  end

  let(:from_uri) { URI("http://127.0.0.1:12345/droplet") }
  let(:to_file) { Tempfile.new("some_dest") }
  let(:sha) { "DEADBEEF" }

  it "fails when the file isn't found" do
    stub_request(:get, from_uri.to_s).to_return(status: 404)

    Download.new(from_uri, to_file, ).download! do |error|
      error.message.should match(/status: 404/)
      done
    end
  end

  it "should fail when response payload has invalid SHA1" do
    stub_request(:get, from_uri.to_s).to_return(body: "fooz")

    Download.new(from_uri, to_file, sha).download! do |err|
      err.message.should match(/SHA1 mismatch/)
      done
    end
  end

  it "should download the file if the sha1 matches" do
    body = "The Body"

    stub_request(:get, from_uri.to_s).to_return(body: body)

    expected = Digest::SHA1.new
    expected << body

    Download.new(from_uri, to_file, expected.hexdigest).download! do |err|
      err.should be_nil
      File.read(to_file).should == body
      done
    end
  end

  it "saves the file in binary mode to work on Windows" do
    body = "The Body"

    stub_request(:get, from_uri.to_s).to_return(body: body)

    expected = Digest::SHA1.new
    expected << body

    the_tempfile = double("tempfile").as_null_object
    Tempfile.stub(:new => the_tempfile)
    Tempfile.should_receive(:new).once
    the_tempfile.should_receive(:binmode).once
    Download.new(from_uri, to_file, expected.hexdigest).download! { done }
  end

  context "when the download causes an exception" do
    it "catches the error but logs it (we really need an airbrake-esque thing" do
      stub_request(:get, from_uri.to_s).to_return(body: "some body")

      expect {
        Download.new(from_uri, to_file).download! do |err|
          raise "Some Terrible Error"
        end
      }.to_not raise_error

      done
    end

    it "copes if the errback fails" do
      expect {
        Download.new(from_uri, to_file).download! do |err|
          raise "Some Terrible Error"
        end
      }.to_not raise_error

      done
    end
  end

  context "when the sha is not given" do
    it "does not verify the sha1" do
      body = "The Body"

      stub_request(:get, from_uri.to_s).to_return(body: body)

      Download.new(from_uri, to_file).download! do |err|
        err.should be_nil
        File.read(to_file).should == body
        done
      end
    end
  end
end

describe Download::DownloadError do
  let(:uri) { URI("http://user:password@example.com/droplet") }
  let(:data) { {:droplet_uri => uri} }
  let(:msg) { "Error message" }
  let(:error) { Download::DownloadError.new(msg, data) }

  it "should not contain credentials in the message" do
    error.message.should_not match(/user/)
    error.message.should_not match(/password/)
  end

  it "should not contain credentials when inspected" do
    error.inspect.should_not match(/user/)
    error.inspect.should_not match(/password/)
  end

  describe "#uri" do
    context "when data contains droplet_uri" do
      it "should return the uri" do
        error.uri.should be(uri)
      end
    end

    context "when data does not contain droplet_uri" do
      let (:data) { {} }

      it "should return '(unknown)'" do
        error.uri.should eq("(unknown)")
      end
    end
  end
end
