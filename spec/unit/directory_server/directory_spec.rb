  # coding: UTF-8

require "rack/test"
require "spec_helper"

require "dea/directory"
require "dea/starting/instance"
require "dea/starting/instance_registry"

describe Dea::Directory do
  include Rack::Test::Methods

  let(:bootstrap) { double(:bootstrap, :config => {}) }
  let(:instance) { Dea::Instance.new(bootstrap, {}) }
  let(:container) { double(:fake_container, :path => @tmpdir) }

  let(:instance_registry) do
    instance_registry = nil
    em do
      instance_registry = Dea::InstanceRegistry.new
      instance_registry.register(instance)
      done
    end
    instance_registry
  end

  let(:app) { Dea::Directory.new(instance_registry) }

  before :each do
    @tmpdir = Dir.mktmpdir

    @home_dir = File.join(@tmpdir, "rootfs", "home", "vcap")
    FileUtils.mkdir_p(@home_dir)

    @app_dir = File.join(@home_dir, "app")
    FileUtils.mkdir(@app_dir)

    @logs_dir = File.join(@home_dir, "logs")
    FileUtils.mkdir(@logs_dir)

    @sentinel_path = File.join(@app_dir, "sentinel")
    @sentinel_contents = "A" * 10_000
    File.open(@sentinel_path, "w+") { |f| f.write(@sentinel_contents) }

    attributes = {
      "instance_id"           => instance.instance_id,
    }

    instance.stub(:attributes).and_return(attributes)
    instance.stub(:container).and_return(container)
    instance.stub(:instance_path_available?).and_return(true)
  end

  after :each do
    FileUtils.rm_rf(@tmpdir)
  end

  it "should return a 404 for unknown instances" do
    get "/unknown"

    last_response.status.should == 404
  end

  it "should return a 404 if the instance is unavailable" do
    instance.stub(:instance_path_available?).and_return(false)

    get "#{instance.instance_id}"

    last_response.status.should == 404
  end

  it "should return a 404 if the requested file doesn't exist" do
    get "#{instance.instance_id}/nonexistant/path"

    last_response.status.should == 404
  end

  it "should return file contents for files that exist" do
    get "#{instance.instance_id}/app/sentinel"

    last_response.should be_ok
    last_response.body.should == @sentinel_contents
  end

  it "should list directories" do
    get "#{instance.instance_id}"

    last_response.should be_ok
    last_response.body.should match(/app\//)
    last_response.body.should match(/logs\//)

    get "#{instance.instance_id}/app"
    last_response.body.should match(/sentinel\s+\d+\.?\d?K/)
  end

  it "should forbid requests containing relative path operators" do
    get "#{instance.instance_id}/../.."

    last_response.status.should == 403
  end

  it "should forbid requests for startup scripts" do
    FileUtils.touch(File.join(@app_dir, "startup"))

    get "#{instance.instance_id}/app/startup"

    last_response.status.should == 403
  end

  it "should forbid requests for stop scripts" do
    FileUtils.touch(File.join(@app_dir, "stop"))

    get "#{instance.instance_id}/app/stop"

    last_response.status.should == 403
  end

  it "should forbid requests for symlinks outside the container", unix_only: true do
    FileUtils.symlink(@tmpdir, File.join(@app_dir, "invalid_symlink"))

    get "#{instance.instance_id}/app/invalid_symlink"

    last_response.status.should == 403
  end

  it "should resolve symlinks inside the container", unix_only: true do
    src_path = File.join(@app_dir, "symlink_target")
    FileUtils.touch(src_path)
    FileUtils.symlink(src_path, File.join(@app_dir, "valid_symlink"))

    get "#{instance.instance_id}/app/valid_symlink"

    last_response.should be_ok
  end
end
