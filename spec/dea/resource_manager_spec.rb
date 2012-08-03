# coding: UTF-8

require "spec_helper"

require "dea/resource_manager"

describe Dea::ResourceManager::Resource do
  describe "#reserve" do
    it "should return the requested amount if available" do
      resource = Dea::ResourceManager::Resource.new("test", 10, 1)
      resource.reserve(5).should == 5
    end

    it "should return nil if the request amount isn't available" do
      resource = Dea::ResourceManager::Resource.new("test", 10, 1)
      resource.reserve(15).should be_nil
    end

    it "should handle overcommit" do
      resource = Dea::ResourceManager::Resource.new("test", 10, 1.5)
      resource.reserve(15).should == 15
    end
  end

  describe "#release" do
    it "should increase remaining resources by the appropriate amount" do
      resource = Dea::ResourceManager::Resource.new("test", 10, 1.5)
      resource.reserve(15).should == 15
      resource.release(10)
      resource.remain.should == 10
      resource.reserve(10).should == 10
    end
  end

  describe "#could_reserve?" do
    it "should return true if a sufficient amount is available" do
      resource = Dea::ResourceManager::Resource.new("test", 10, 1)
      resource.could_reserve?(10).should be_true
    end

    it "should return false if a sufficient amount is not available" do
      resource = Dea::ResourceManager::Resource.new("test", 10, 1)
      resource.could_reserve?(20).should be_false
    end
  end
end

describe Dea::ResourceManager do
  let(:manager) do
    Dea::ResourceManager.new("memory_mb" => 100, "memory_overcommit_factor" => 1.5,
                             "disk_mb" => 100, "disk_overcommit_factor" => 1.5,
                             "num_instances" => 100)
  end

  describe "could_reserve?" do
    it "should return false if any resources are insufficient" do
      manager.could_reserve?(200, 50, 50).should be_false # mem
      manager.could_reserve?(50, 200, 50).should be_false # disk
      manager.could_reserve?(50, 50, 200).should be_false # instances
    end

    it "should return true if all resources are available" do
      manager.could_reserve?(50, 50, 50).should be_true
    end
  end

  describe "reserve" do
    it "should return reservation if all resources are available" do
      expected = {
        "memory"        => 50,
        "disk"          => 50,
        "num_instances" => 50,
      }
      manager.reserve(50, 50, 50).should == expected
    end

    it "should return nil if any resources aren't available" do
      manager.reserve(50, 200, 50).should be_nil
    end
  end
end
