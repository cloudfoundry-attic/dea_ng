require "spec_helper"

describe Buildpacks::Procfile, :type => :buildpack do
  let(:contents) { {"web" => "something"} }
  let(:path) { procfile.path }
  let(:procfile) do
    file = Tempfile.new('foo')
    file.write(contents.to_yaml)
    file.close
    file
  end

  describe "#contents" do
    it "should only read the file contents once" do
      allow(YAML).to receive(:load).with(anything).once.and_call_original
      file = Buildpacks::Procfile.new(path)
      file.contents
      file.contents
    end

    context "when its on the filesystem" do
      it "loads the contents" do
        expect(Buildpacks::Procfile.new(path).contents).to eq contents
      end
    end

    context "when procfile is not a hash" do
      let(:contents) { "some non hash thing" }
      it "raises an exception" do
        expect { Buildpacks::Procfile.new(path).contents }.to raise_error ArgumentError
      end
    end

    context "when its not found" do
      let(:path) { "/non_existant_file" }
      it "does not fail" do
        expect(Buildpacks::Procfile.new(path).contents).to be_nil
      end
    end
  end

  describe "#web" do
    it "get the web key" do
      expect(Buildpacks::Procfile.new(path).web).to eq "something"
    end

    context "when the contents does not exist" do
      let(:path) { "/non_existant_file" }
      it "returns nil" do
        expect(Buildpacks::Procfile.new(path).web).to be_nil
      end
    end

    context "when web does not exist" do
      let(:contents) { {"foobar" => "something"} }
      it "returns nil" do
        expect(Buildpacks::Procfile.new(path).web).to be_nil
      end
    end
  end
end
