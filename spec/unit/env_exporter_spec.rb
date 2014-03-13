require "spec_helper"
require "dea/env_exporter"

describe Dea::EnvExporter do
  subject(:env_exporter) { Dea::EnvExporter.new(variables) }

  context "with a single value" do
    let(:variables) { {a: 1} }

    it "exports the variables" do
      expect(env_exporter.export).to eql(%Q{export a="1";\n})
    end
  end

  context "with multiple values" do
    let(:variables) { {a: 1, b: 2} }

    it "exports the variables" do
      expect(env_exporter.export).to eql(%Q{export a="1";\nexport b="2";\n})
    end
  end

  context "with value containing quotes" do
    let(:variables) { {a: %Q{"1'}} }

    it "exports the variables" do
      expect(env_exporter.export).to eql(%Q{export a="\\"1'";\n})
    end
  end

  context "with non-string values" do
    let(:variables) { {:a => :b} }

    it "exports the variables" do
      expect(env_exporter.export).to eql(%Q{export a="b";\n})
    end
  end

  context "with spaces in values" do
    let(:variables) { {:a => "one two"} }

    it "exports the variables" do
      expect(env_exporter.export).to eql(%Q{export a="one two";\n})
    end
  end

  context "with = in values" do
    let(:variables) { {:a => "one=two"} }

    it "exports the variables" do
      expect(env_exporter.export).to eql(%Q{export a="one=two";\n})
    end
  end
end
