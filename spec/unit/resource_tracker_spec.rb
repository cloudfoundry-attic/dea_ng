$:.unshift(File.dirname(__FILE__))
require 'spec_helper'
require 'resource_tracker'

describe VCAP::Dea::ResourceTracker do
  before(:all) do
    resources = {:memory => 100, :disk => 100, :instances => 100}
    @tracker = VCAP::Dea::ResourceTracker.new(resources)
  end

  it 'should allow resources to be reserved' do
    request = {:memory => 10, :disk => 10, :instances => 10 }
    reserved = @tracker.reserve(request)
    reserved.should == request
  end

  it 'should not allow resources to be reserved if any resource has insufficient capacity' do
    request = {:memory => 100, :disk => 100, :instances => 100 }
    @tracker.reserve(request).should be_nil
  end

   it 'should allow capacity to be returned' do
     final_state = {:memory => 0, :disk => 0, :instances => 0 }
     @tracker.release(@tracker.reserved)
     @tracker.reserved.should == final_state
   end
end
