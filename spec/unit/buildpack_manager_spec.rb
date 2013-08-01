# coding: UTF-8

require "spec_helper"
require "dea/buildpack_manager"
require "dea/nats"

describe Dea::BuildpackManager do
  let(:manager) { Dea::BuildpackManager.new }

  describe "#add_buildpack" do
    it "clones the buildpack into the directory matching the given name" do
      data = {
          "name" => "liberty",
          "url" => "git://example.com/foo/liberty-buildpack.git"
      }
      message = Dea::Nats::Message.new(nil, "buildpacks.add", data, "buildpacks.add.response")

      expected_path = File.expand_path("../../../buildpacks/vendor/liberty", __FILE__)
      manager.should_receive(:system).with(kind_of String) do |cmd|
        expect(cmd).to eq("git clone --recursive git://example.com/foo/liberty-buildpack.git #{expected_path}")
        true
      end

      expect(manager.add_buildpack(message)).to eq(true)
    end

    it "returns false if the name contains invalid characters . or /" do
      data = {
          "name" => "../../../liberty",
          "url" => "git://example.com/foo/liberty-buildpack.git"
      }
      message = Dea::Nats::Message.new(nil, "buildpacks.add", data, "buildpacks.add.response")

      manager.should_not_receive(:system)

      expect(manager.add_buildpack(message)).to eq(false)
    end

    it "does nothing if the buildpack is already present" do
      data = {
          "name" => "java",
          "url" => "git://example.com/foo/liberty-buildpack.git"
      }
      message = Dea::Nats::Message.new(nil, "buildpacks.add", data, "buildpacks.add.response")

      manager.should_not_receive(:system)

      expect(manager.add_buildpack(message)).to eq(true)
    end
  end
end