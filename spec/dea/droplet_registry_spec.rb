# coding: UTF-8

require "spec_helper"
require "digest/sha1"
require "dea/droplet_registry"

describe Dea::DropletRegistry do
  include_context "tmpdir"

  let(:payload) do
    "droplet"
  end

  let(:sha1) do
    Digest::SHA1.hexdigest(payload)
  end

  subject(:droplet_registry) do
    Dea::DropletRegistry.new(tmpdir)
  end

  it { should be_kind_of(Hash) }

  it "should create Droplet objects when indexed" do
    droplet_registry[sha1].should be_kind_of(Dea::Droplet)
  end

  it "should initialize with existing droplets" do
    sha1s = 3.times.map do |i|
      Digest::SHA1.hexdigest(i.to_s).tap do |sha1|
        FileUtils.mkdir_p(File.join(tmpdir, sha1))
      end
    end

    droplet_registry = Dea::DropletRegistry.new(tmpdir)
    droplet_registry.should have(3).droplets
    droplet_registry.keys.sort.should == sha1s.sort
  end
end
