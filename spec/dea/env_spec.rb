# coding: UTF-8

require "spec_helper"

require "vcap/common"

require "dea/env"

describe Dea::Env do
  let(:service) do
    {
      "name"        => "name",
      "type"        => "type",
      "label"       => "label",
      "vendor"      => "vendor",
      "version"     => "version",
      "tags"        => { "key" => "value" },
      "plan"        => "plan",
      "plan_option" => "plan_option",
      "credentials" => {
        "user" => "password",
        "host" => "host",
        "port" => "port",
      },
      "invalid"     => "invalid",
    }
  end

  let(:instance_attributes) do
    {
      "instance_id"         => VCAP.secure_uuid,
      "instance_index"      => 37,

      "application_id"      => 37,
      "application_version" => "some_version",
      "application_name"    => "my_application",
      "application_uris"    => ["foo.com", "bar.com"],

      "droplet_sha1"        => "deadbeef",
      "droplet_uri"         => "http://foo.com/file.ext",

      "limits"              => { "mem" => 1, "disk" => 2, "fds" => 3 },
      "environment"         => { "FOO" => "BAR" },
      "services"            => { "name" => "redis", "type" => "redis" },
      "flapping"            => false,
    }
  end

  let(:instance) do
    mock("Dea::Instance")
  end

  subject(:env) do
    Dea::Env.new(instance)
  end

  describe "#services_for_json" do
    let(:services) do
      [service]
    end

    let(:services_for_json) do
      env.services_for_json
    end

    before do
      instance.stub(:services).and_return(services)
    end

    it "returns a Hash" do
      services_for_json.should be_a(Hash)
    end

    keys = %W(
      name
      label
      tags
      plan
      plan_option
      credentials
    )

    keys.each do |key|
      it "includes #{key.inspect}" do
        services_for_json[service["label"]].first.should include(key)
      end
    end

    it "doesn't include unknown keys" do
      services_for_json[service["label"]].should have(1).service
      services_for_json[service["label"]].first.keys.should_not include("invalid")
    end

    describe "grouping" do
      let(:services) do
        [
          service.merge("label" => "l1"),
          service.merge("label" => "l1"),
          service.merge("label" => "l2"),
        ]
      end

      it "should group services by label" do
        services_for_json.should have(2).groups
        services_for_json["l1"].should have(2).services
        services_for_json["l2"].should have(1).service
      end
    end

    describe "ignoring" do
      let(:services) do
        [service.merge("name" => nil)]
      end

      it "should ignore keys with nil values" do
        services_for_json[service["label"]].should have(1).service
        services_for_json[service["label"]].first.keys.should_not include("name")
      end
    end
  end

  describe "#application_for_json" do
    let(:application_for_json) do
      env.application_for_json
    end

    before do
      instance_attributes.each do |key, value|
        instance.stub(key).and_return(value)
      end

      instance.stub(:state_starting_timestamp).and_return(Time.now.to_f)

      instance.stub(:instance_container_port).and_return(4567)
    end

    it "returns a Hash" do
      application_for_json.should be_a(Hash)
    end

    keys = %W(
      instance_id
      instance_index

      application_version
      application_name
      application_uris
      application_users
    )

    keys.each do |key|
      it "includes #{key.inspect}" do
        application_for_json.should include(key)
      end
    end

    it "includes the time the instance was started" do
      application_for_json["started_at"].should be_a(Time)
      application_for_json["started_at_timestamp"].should be_a(Integer)
    end

    it "includes the host and port the instance should listen on" do
      application_for_json["host"].should be
      application_for_json["port"].should == 4567
    end

    it "includes the resource limits" do
      application_for_json["limits"].should be_a(Hash)
    end

    describe "translation" do
      translations = {
        "application_version"  => "version",
        "application_name"     => "name",
        "application_uris"     => "uris",
        "application_users"    => "users",

        "started_at"           => "start",
        "started_at_timestamp" => "state_timestamp",
      }

      translations.each do |from, to|
        it "should translate #{from.inspect} to #{to.inspect}" do
          application_for_json[to].should == application_for_json[from]
        end
      end
    end
  end

  describe "#env" do
    let(:application_for_json) do
      {
        "host"        => "localhost",
        "name"        => "name",
        "instance_id" => "instance_id",
        "version"     => "version",
      }
    end

    let(:services_for_json) do
      {
        "label" => {
          "name" => "service",
        },
      }
    end

    let(:legacy_services_for_json) do
      {
        "tier" => "free"
      }
    end

    before do
      subject.stub(:application_for_json).and_return(application_for_json)
      subject.stub(:services_for_json).and_return(services_for_json)
      subject.stub(:legacy_services_for_json).and_return(legacy_services_for_json)

      instance.stub(:instance_container_port).and_return(4567)
      instance.stub(:instance_debug_container_port).and_return(4568)
      instance.stub(:instance_console_container_port).and_return(4569)
      instance.stub(:services).and_return([service])

      instance.stub(:debug).and_return(nil)

      instance.stub(:environment).and_return({ "ENVIRONMENT" => "yep" })
      instance.stub(:bootstrap).and_return do
        mock("bootstrap", :config => {})
      end
    end

    def find(key)
      pair = subject.env.find { |e| e[0] == key }
      pair[1] if pair
    end

    it "includes VCAP_APPLICATION" do
      find("VCAP_APPLICATION").should include(Yajl::Encoder.encode(application_for_json))
    end

    it "includes VCAP_SERVICES" do
      find("VCAP_SERVICES").should include(Yajl::Encoder.encode(services_for_json))
    end

    it "includes VCAP_APP_*" do
      find("VCAP_APP_HOST").should =~ /#{application_for_json["host"]}/
      find("VCAP_APP_PORT").should =~ /4567/
    end

    it "does not includes VCAP_DEBUG_*" do
      find("VCAP_DEBUG_IP").should be_nil
      find("VCAP_DEBUG_PORT").should be_nil
    end

    it "includes VCAP_CONSOLE_*" do
      find("VCAP_CONSOLE_IP").should =~ /#{application_for_json["host"]}/
      find("VCAP_CONSOLE_PORT").should =~ /4569/
    end

    it "includes the debug mode when the debug mode is set" do
      instance.stub(:debug).and_return("mode")
      find("VCAP_DEBUG_MODE").should == "'mode'"
    end

    it "doesn't include the debug mode when debug mode is not set" do
      instance.stub(:debug).and_return(nil)
      find("VCAP_DEBUG_MODE").should_not be
    end

    it "includes the user-specified environment" do
      find("ENVIRONMENT").should be
    end

    it "wraps user-specified environment in double quotes if it isn't already" do
      find("ENVIRONMENT").should == %{"yep"}
    end

    context "when in debug mode" do
      before { instance.stub(:debug).and_return(true) }

      it "does not includes VCAP_DEBUG_*" do
        find("VCAP_DEBUG_IP").should =~ /#{application_for_json["host"]}/
        find("VCAP_DEBUG_PORT").should =~ /4568/
      end
    end
  end
end
