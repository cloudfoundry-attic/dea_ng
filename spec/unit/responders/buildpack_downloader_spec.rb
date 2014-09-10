require "spec_helper"
require "dea/nats"
require "dea/directory_server/directory_server_v2"

require "dea/staging/staging_task_registry"

require "dea/responders/buildpack_downloader"

describe Dea::Responders::BuildpackDownloader do
  stub_nats

  let(:nats) { Dea::Nats.new(bootstrap, config) }
  let(:bootstrap) { double(:bootstrap, :config => config) }
  let(:config) { {"directory_server" => {"file_api_port" => 2345}} }

  let(:downloader) { double(:admin_buildpack_downloader, :download => true) }

  subject { described_class.new(nats, config) }

  describe "#start" do
    context "when config does not allow staging operations" do
      before { config.delete("staging") }

      it "does not listen to 'buildpacks'" do
        subject.start
        expect(subject).not_to receive(:handle)
        nats_mock.publish("buildpacks")
      end
    end

    context "when the config allows staging operations" do
      before { config["staging"] = {"enabled" => true} }

      it "subscribes to the 'buildpacks' message" do
        subject.start
        expect(subject).to receive(:handle)
        nats_mock.publish("buildpacks")
      end

      it "manually tracks the subscription" do
        expect(nats).to receive(:subscribe).with("buildpacks", hash_including(do_not_track_subscription: true))
        subject.start
      end
    end
  end

  describe "#stop" do
    before { config["staging"] = {"enabled" => true} }

    context "when subscription was made" do
      before { subject.start }

      it "unsubscribes from 'buildpacks' message" do
        expect(subject).to receive(:handle) # sanity check
        nats_mock.publish("buildpacks")

        subject.stop
        expect(subject).not_to receive(:handle)
        nats_mock.publish("buildpacks")
      end
    end
  end

  describe "#handle" do
    let(:message) do
      double(:message, data: [
        { "key" => "abcd", "url" => "http://abcd" },
        { "key" => "easyas", "url" => "http://123" }
      ])
    end

    before do
      config["base_dir"] = "/heavy_base_dir" 
      allow(FileUtils).to receive(:mkdir_p)
    end

    it "asks buildpack downloader to download buildpacks" do
      expect(AdminBuildpackDownloader).to receive(:new).with([
        { key: 'abcd', url: URI('http://abcd') },
        { key: 'easyas', url: URI('http://123') }
      ], kind_of(String), duck_type(:debug, :error, :info)).and_return(downloader)

      subject.handle(message)
      expect(downloader).to have_received(:download)
    end

    it "asks buildpack downloader to download to correct directory" do
      expect(AdminBuildpackDownloader).to receive(:new).with(anything, "/heavy_base_dir/admin_buildpacks", duck_type(:debug, :error, :info)).and_return(downloader)

      subject.handle(message)
      expect(downloader).to have_received(:download)
    end
  end
end
