require "spec_helper"
require "dea/config"

describe Dea::Config do
  describe "config/dea.yml" do
    it "can load" do
      file_path = File.expand_path("../../../config/dea.yml", __FILE__)
      described_class.from_file(file_path).should be_a(described_class)
    end
  end
end
