require "spec_helper"
require "dea/directory_server/hmac_helper"

describe HMACHelper do
  subject { HMACHelper.new("key") }

  # echo -n "value" | openssl dgst -sha512 -hmac "key"
  VALUE_HMAC = "86951dc765bef95f9474669cd18df7705d99ae47ea3e76a2ca4c22f71656f42ea66e3acdc898c93f475009fa599d0bb83bd5365f36a9cb92c570708f8de5fae8"

  describe "#initialize" do
    it "raises error when key is nil" do
      expect do
        HMACHelper.new(nil)
      end.to raise_error(ArgumentError, /key must not be nil/)
    end
  end

  describe "#create" do
    it "returns sha1 hmac value" do
      expect(subject.create("value")).to eq(VALUE_HMAC)
    end
  end

  describe "#compare" do
    context "when string hmac matches given hmac" do
      it "returns true" do
        expect(subject.compare(VALUE_HMAC, "value")).to be true
      end
    end

    context "when string hmac does not given hmac" do
      it "returns false" do
        expect(subject.compare(VALUE_HMAC, "value1")).to be false
      end
    end
  end
end
