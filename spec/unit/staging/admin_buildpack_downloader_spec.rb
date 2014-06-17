require "spec_helper"
require "dea/staging/admin_buildpack_downloader"

describe AdminBuildpackDownloader do
  let(:logger) { double("logger").as_null_object }
  let(:zip_file) { fixture("buildpack.zip") }
  let(:destination_directory) { Dir.mktmpdir }

  after { FileUtils.rm_f(destination_directory) }

  subject(:downloader) do
    AdminBuildpackDownloader.new(buildpacks, destination_directory, logger)
  end

  context "with single buildpack" do
    let(:buildpacks) do
      [
        {
          url: URI("http://example.com/buildpacks/uri/abcdef"),
          key: "abcdef"
        }
      ]
    end

    before do
      stub_request(:any, "http://example.com/buildpacks/uri/abcdef").to_return(
          body: File.new(zip_file)
      )
    end

    it "downloads the buildpack and unzip it" do
      do_download
      expected_file_name = File.join(destination_directory, "abcdef")
      expect(File.exist?(expected_file_name)).to be_true
      expect(sprintf("%o", File.stat(expected_file_name).mode)).to eq("40755")
      expect(Dir.entries(expected_file_name)).to include("content")
    end

    it "doesn't download buildpacks it already has" do
      File.stub(:exists?).with(File.join(destination_directory, "abcdef")).and_return(true)
      Download.should_not_receive(:new)
      downloader.download
    end
  end

  context "with multiple buildpacks" do
    let(:buildpacks) do
      [
        {
          url: URI("http://example.com/buildpacks/uri/abcdef"),
          key: "abcdef"
        },
        {
          url: URI("http://example.com/buildpacks/uri/ijgh"),
          key: "ijgh"
        }
      ]
    end

    before do
      stub_request(:any, "http://example.com/buildpacks/uri/ijgh").to_return(
          body: File.new(zip_file)
      )
    end

    it "only returns when all the downloads are done" do
      stub_request(:any, "http://example.com/buildpacks/uri/abcdef").to_return(
          body: File.new(zip_file)
      )

      do_download
      expect(Dir.entries(File.join(destination_directory))).to include("ijgh")
      expect(Dir.entries(File.join(destination_directory))).to include("abcdef")
      expect(Pathname.new(destination_directory).children).to have(2).items
    end

    it "raises an exception if the download fails" do
      stub_request(:any, "http://example.com/buildpacks/uri/abcdef").to_return(
        :status => [500, "Internal Server Error"]
      )
      expect {
        do_download
      }.to raise_error

      expect(Pathname.new(destination_directory).children).to have(0).item
    end
  end

  def do_download
    failure = nil
    EM.run do
      Fiber.new do
        begin
          downloader.download
        rescue => error
          failure = error
        ensure
          EM.stop
        end
      end.resume
    end

    raise failure unless failure.nil?
  end
end
