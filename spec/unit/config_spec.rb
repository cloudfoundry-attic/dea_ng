require "spec_helper"
require "dea/config"

describe Dea::Config do
  let(:file_path){ File.expand_path("../../../config/dea.yml", __FILE__) }
  subject{ described_class.from_file(file_path) }

  describe "config/dea.yml" do
    it "can load" do
      subject.should be_a(described_class)
    end
  end

  describe "placement_properties in config/dea.yml" do
    it "can parse placement properties" do
      subject["placement_properties"].fetch("zone", "default").should == "zone1"
    end
  end
end
