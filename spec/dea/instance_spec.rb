# coding: UTF-8

require "spec_helper"
require "dea/instance"

describe Dea::Instance do
  let(:valid_attributes) do
    {
      "instance_index"      => 37,

      "application_id"      => 37,
      "application_version" => "some_version",
      "application_name"    => "my_application",
      "application_uris"    => ["foo.com", "bar.com"],
      "application_users"   => ["john@doe.com"],

      "droplet_sha1"        => "deadbeef",
      "droplet_file"        => "file.ext",
      "droplet_uri"         => "http://foo.com/file.ext",

      "runtime_name"        => "ruby19",
      "framework_name"      => "rails",

      "limits"              => { "mem" => 1, "disk" => 2, "fds" => 3 },
      "environment"         => { "FOO" => "BAR" },
      "services"            => { "name" => "redis", "type" => "redis" },
      "flapping"            => false,
      "debug"               => "debug",
      "console"             => "console",
    }
  end

  let(:bootstrap) do
    mock("bootstrap")
  end

  describe "attributes from start message" do
    let(:start_message) do
      message = double("message")

      # Fixture to make sure Dea::Instance.create_from_message doesn't throw up
      defaults = {
        "index"   => 0,
        "droplet" => 1,
      }

      message.stub(:data).and_return(defaults.merge(start_message_data))
      message
    end

    subject(:instance) do
      Dea::Instance.new(bootstrap, Dea::Instance.translate_attributes(start_message.data))
    end

    describe "instance attributes" do
      let(:start_message_data) do
        {
          "index" => 37,
        }
      end

      its(:instance_id)    { should be }
      its(:instance_index) { should == 37 }
    end

    describe "application attributes" do
      let(:start_message_data) do
        {
          "droplet" => 37,
          "version" => "some_version",
          "name"    => "my_application",
          "uris"    => ["foo.com", "bar.com"],
          "users"   => ["john@doe.com"],
        }
      end


      its(:application_id)      { should == 37 }
      its(:application_version) { should == "some_version" }
      its(:application_name)    { should == "my_application" }
      its(:application_uris)    { should == ["foo.com", "bar.com"] }
      its(:application_users)   { should == ["john@doe.com"] }
    end

    describe "droplet attributes" do
      let(:start_message_data) do
        {
          "sha1"           => "deadbeef",
          "executableFile" => "file.ext",
          "executableUri"  => "http://foo.com/file.ext",
        }
      end

      its(:droplet_sha1) { should == "deadbeef" }
      its(:droplet_file) { should == "file.ext" }
      its(:droplet_uri)  { should == "http://foo.com/file.ext" }
    end

    describe "runtime/framework attributes" do
      let(:start_message_data) do
        {
          "runtime"   => "ruby19",
          "framework" => "rails",
        }
      end

      its(:runtime_name)   { should == "ruby19" }
      its(:framework_name) { should == "rails" }
    end

    describe "other attributes" do
      let(:start_message_data) do
        {
          "limits"   => { "mem" => 1, "disk" => 2, "fds" => 3 },
          "env"      => { "FOO" => "BAR" },
          "services" => { "name" => "redis", "type" => "redis" },
          "flapping" => false,
          "debug"    => "debug",
          "console"  => "console",
        }
      end

      its(:limits)      { should == { "mem" => 1, "disk" => 2, "fds" => 3 } }
      its(:environment) { should == { "FOO" => "BAR" } }
      its(:services)    { should == { "name" => "redis", "type" => "redis" } }
      its(:flapping)    { should == false }
      its(:debug)       { should == "debug" }
      its(:console)     { should == "console" }
    end
  end

  describe "validation" do
    before do
      bootstrap.stub(:runtimes).and_return(Hash.new { |*_| "runtime" })
    end

    it "should not raise when the attributes are valid" do
      instance = Dea::Instance.new(bootstrap, valid_attributes)

      expect do
        instance.validate
      end.to_not raise_error
    end

    it "should raise when attributes are missing" do
      attributes = valid_attributes.dup
      attributes.delete("application_id")
      instance = Dea::Instance.new(bootstrap, attributes)

      expect do
        instance.validate
      end.to raise_error
    end

    it "should raise when attributes are invalid" do
      attributes = valid_attributes.dup
      attributes["application_id"] = attributes["application_id"].to_s
      instance = Dea::Instance.new(bootstrap, attributes)

      expect do
        instance.validate
      end.to raise_error
    end

    it "should raise when the runtime is not found" do
      attributes = valid_attributes.dup
      attributes["runtime_name"] = "not_found"

      instance = Dea::Instance.new(bootstrap, attributes)

      bootstrap.should_receive(:runtimes).and_return({})

      expect do
        instance.validate
      end.to raise_error(Dea::Instance::RuntimeNotFoundError)
    end
  end

  describe "start transition" do
    subject(:instance) do
      Dea::Instance.new(bootstrap, valid_attributes)
    end

    let(:droplet) do
      droplet = mock("droplet")
      droplet.stub(:droplet_exist?).and_return(true)
      droplet
    end

    before do
      instance.stub(:droplet).and_return(droplet)
    end

    it "should raise when not in the start state" do
      em do
        instance.state = "blah"

        instance.start do |err|
          err.should be_kind_of(Dea::Instance::BaseError)
          err.message.should match(/transition/)
          done
        end
      end
    end

    it "should raise when downloading droplet fails" do
      em do
        droplet.stub(:droplet_exist?).and_return(false)
        droplet.stub(:download).and_yield(Dea::Instance::BaseError.new("download failed"))

        instance.start do |err|
          err.should be_kind_of(Dea::Instance::BaseError)
          err.message.should match(/download failed/)
          done
        end
      end
    end
  end
end
