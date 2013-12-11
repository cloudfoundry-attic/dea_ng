require "spec_helper"
require "dea/config"

module Dea
  describe Config do

    describe ".from_file" do
      let(:file_path) { File.expand_path("../../../config/dea.yml", __FILE__) }
      subject { described_class.from_file(file_path) }

      it "can load" do
        should be_a(described_class)
      end
    end

    describe "#initialize" do
      subject(:config) { described_class.new({}) }

      it "can load" do
        should be_a(described_class)
      end

      describe "the available keys and values" do
        let(:config_as_hash) do
          config.inject({}) do |hash, kv|
            hash[kv[0]] = kv[1]
            hash
          end
        end

        it "has the expected default keys" do
          config_as_hash.keys.should eq(Config::EMPTY_CONFIG.keys)
        end

        it "has the expected default values" do
          config_as_hash.values.should eq(Config::EMPTY_CONFIG.values)
        end
      end
    end

    describe "#placement_properties" do
      subject(:config) { described_class.new(config_hash) }

      context "when the config hash has no key for placement_properties:" do
        let(:config_hash) { { } }

        it "has a sane default" do
          config["placement_properties"].should == { "zone" => "default" }
        end
      end

      context "when the config hash has a key for placement_properties:" do
        let(:config_hash) { { "placement_properties" => { "zone" => "CRAZY_TOWN" } } }

        it "uses the zone provided by the hash" do
          config["placement_properties"].should == { "zone" => "CRAZY_TOWN" }
        end
      end
    end
  end
end
