$:.unshift(File.dirname(__FILE__))
require 'spec_helper'
require 'fileutils'
require 'app_cache'

describe VCAP::Dea::AppCache do
  before(:all) do
    #XXX this is ugly, replace with an appropriate tmp directory.
    @directories = {'droplets' => '/tmp/droplets', 'tmp' => '/tmp/tmp'}
    @directories.each_value {|path| FileUtils.mkdir_p path}
    @cache = VCAP::Dea::AppCache.new(@directories)
    #XXX non-deterministically fails, should do something smarter.
    @test_uri = 'http://production.cf.rubygems.org/rubygems/rubygems-1.8.21.tgz'
    @test_sha1 = '2a179f5820a085864f7f3659dc8bb3307ee2cf4e'
  end

  after(:all) do
    @directories.each_value {|path| FileUtils.rm_rf path }
  end

  it "should check if an app is present" do
    @cache.has_droplet?('fake').should == false
  end

  it "should download and verify an app" do
    em_fiber_wrap {@cache.download_droplet(@test_uri, @test_sha1)}
  end

  it "should purge a downloaded app" do
    em_fiber_wrap {@cache.purge_droplet!(@test_sha1)}
  end

end
