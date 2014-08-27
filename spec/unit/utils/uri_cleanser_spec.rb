require 'spec_helper'
require 'dea/utils/uri_cleaner'

describe URICleaner do

  describe "strings as uris" do
    let (:uri) { "nats://user:password@server:4222" }

    it "removes the password" do
      expect(URICleaner.clean(uri)).to eq("nats://user@server:4222")
    end

    context "when the uri is opaque" do
      let (:uri) { "mailto:user:pass@example.com" }

      it "does not modify opaque urls" do
        expect(URICleaner.clean(uri)).to eq(uri)
      end
    end
  end

  describe "URIs as uris" do
    let (:uri) { "nats://user:password@example.com:4222" }
    let (:uri_object) { URI(uri) }

    it "does not modify the uri" do
      expect {
        URICleaner.clean(uri_object)
      }.to_not change {
        uri_object
      }
    end

    it "returns a string" do
      expect(URICleaner.clean(uri_object)).to be_a(String)
    end

    it "removes the password" do
      expect(URICleaner.clean(uri_object)).to eq("nats://user@example.com:4222")
    end

    context "when the uri is opaque" do
      let (:uri) { "mailto:user:something@example.com" }

      it "does not modify the uri" do
        expect(URICleaner.clean(uri_object)).to eq(uri)
      end
    end
  end

  context "when passed an invalid uri" do
    it "returns an error string" do
      expect(URICleaner.clean("invalid uri")).to match /uri parse error/
    end
  end

  context "when cleaning a list" do
    let (:uris) do
      [
        "https://user:foobar@example.com/",
        "mailto:user@example.com",
        URI("nats://user:password@example.com:4222")
      ]
    end

    it "returns a list of uri strings without passwords" do
      expect(URICleaner.clean(uris)).to eq([
        "https://user@example.com/",
        "mailto:user@example.com",
        "nats://user@example.com:4222"
      ])
    end
  end
end
