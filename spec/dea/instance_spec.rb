require "spec_helper"
require "dea/instance"

describe Dea::Instance do
  let(:bootstrap) do
    mock("bootstrap")
  end

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

  describe "static attributes" do
    subject(:instance) do
      Dea::Instance.create_from_message(bootstrap, start_message)
    end

    describe "instance attributes" do
      let(:start_message_data) do
        {
          "index" => "37",
        }
      end

      its(:instance_id)    { should be }
      its(:instance_index) { should == 37 }
    end

    describe "application attributes" do
      let(:start_message_data) do
        {
          "droplet" => "37",
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

      its(:runtime)   { should == "ruby19" }
      its(:framework) { should == "rails" }
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
end
