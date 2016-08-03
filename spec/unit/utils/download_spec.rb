require "spec_helper"
require "dea/utils/download"

describe Download do
  around do |example|
    with_event_machine { example.call }
  end

  let(:from_uri) { URI("http://127.0.0.1:12345/droplet") }
  let(:to_file) { Tempfile.new("some_dest") }
  let(:sha) { "DEADBEEF" }

  it "fails when the file isn't found" do
    stub_request(:get, from_uri.to_s).to_return(status: 404)

    Download.new(from_uri, to_file, ).download! do |error|
      expect(error.message).to match(/status: 404/)
      done
    end
  end

  it "should fail when response payload has invalid SHA1" do
    stub_request(:get, from_uri.to_s).to_return(body: "fooz")

    Download.new(from_uri, to_file, sha).download! do |err|
      expect(err.message).to match(/SHA1 mismatch/)
      done
    end
  end

  it "should download the file if the sha1 matches" do
    body = "The Body"

    stub_request(:get, from_uri.to_s).to_return(body: body)

    expected = Digest::SHA1.new
    expected << body

    Download.new(from_uri, to_file, expected.hexdigest).download! do |err|
      expect(err).to be_nil
      expect(File.read(to_file)).to eq(body)
      done
    end
  end

  it "saves the file in binary mode to work on Windows" do
    body = "The Body"

    stub_request(:get, from_uri.to_s).to_return(body: body)

    expected = Digest::SHA1.new
    expected << body

    expect(to_file).to receive(:binmode).once
    Download.new(from_uri, to_file, expected.hexdigest).download! { done }
  end

  context "when the download callback causes an exception" do
    context "and the http reqeust returned" do
      it "logs the error and does not blow up" do
        stub_request(:get, from_uri.to_s).to_return(body: "some body")

        expect {
          Download.new(from_uri, to_file).download! do |err|
            raise "Some Terrible Error"
          end
        }.to_not raise_error

        done
      end
    end

    context "and the http request errors out" do
      it "does not raise" do
        expect {
          Download.new(from_uri, to_file).download! do |err|
            raise "Some Terrible Error"
          end
        }.to_not raise_error

        done
      end
    end
  end

  context "when the sha is not given" do
    it "does not verify the sha1" do
      body = "The Body"

      stub_request(:get, from_uri.to_s).to_return(body: body)

      Download.new(from_uri, to_file).download! do |err|
        expect(err).to be_nil
        expect(File.read(to_file)).to eq(body)
        done
      end
    end
  end

  context "when the http request errors" do
    it 'closes the download file' do
      Download.new(from_uri, to_file).download! do |err|
        expect(to_file.closed?).to be true
      end

      done
    end

    it "logs the error and calls the callback with a sensible error" do
      Download.new(from_uri, to_file).download! do |err|
        expect(err.message).to match(/ECONNREFUSED/)
      end

      done
    end
  end
end

describe Download::DownloadError do
  let(:uri) { URI("http://user:password@example.com/droplet") }
  let(:data) { {:droplet_uri => uri} }
  let(:msg) { "Error message" }
  let(:error) { Download::DownloadError.new(msg, data) }

  it "should not contain credentials in the message" do
    expect(error.message).to_not match(/user/)
    expect(error.message).to_not match(/password/)
  end

  it "should not contain credentials when inspected" do
    expect(error.inspect).to_not match(/user/)
    expect(error.inspect).to_not match(/password/)
  end

  describe "#uri" do
    context "when data contains droplet_uri" do
      it "should return the uri" do
        expect(error.uri).to eq(uri)
      end
    end

    context "when data does not contain droplet_uri" do
      let (:data) { {} }

      it "should return '(unknown)'" do
        expect(error.uri).to eq("(unknown)")
      end
    end
  end
end
