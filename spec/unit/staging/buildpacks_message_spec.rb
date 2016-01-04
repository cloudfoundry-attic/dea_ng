require "spec_helper"
require "dea/staging/buildpacks_message"

describe BuildpacksMessage do

  subject { BuildpacksMessage.new(message) }

  context "when the message is empty" do
    let(:message) { [] }

    it "should have an empty buildpack list" do
      expect(subject.buildpacks).to eq([])
    end
  end

  context "when admin build packs are specified" do
    let(:message) do
      [
        {
          "url" => "http://www.example.com/buildpacks/uri/first",
          "key" => "first"
        },
        {
          "url" => "http://www.example.com/buildpacks/uri/second",
          "key" => "second"
        }
      ]
    end

    it "should contain a list of buildpacks" do
      expect(subject.buildpacks).to eq([
        {
          url: URI("http://www.example.com/buildpacks/uri/first"),
          key: "first"
        },
        {
          url: URI("http://www.example.com/buildpacks/uri/second"),
          key: "second"
        }
      ])
    end

    it "should ignore invalid buildpack urls" do
      message[0]["url"] = nil

      expect(subject.buildpacks).to eq([
        {
          url: URI("http://www.example.com/buildpacks/uri/second"),
          key: "second"
        }
      ])
    end
  end
end
