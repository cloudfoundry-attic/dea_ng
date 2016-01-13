require "spec_helper"
require "dea/staging/buildpacks_message"

describe BuildpacksMessage do

  subject { BuildpacksMessage.new(message) }

  context "when the message is empty" do
    let(:message) { [] }
    its(:buildpacks) { should eq([]) }
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

    its(:buildpacks) do
      should eq([
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
