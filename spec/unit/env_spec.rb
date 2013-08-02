# coding: UTF-8

require "spec_helper"
require "vcap/common"
require "dea/env"

describe Dea::Env do
  let(:service) do
    {
      "credentials" => {"uri" => "postgres://user:pass@host:5432/db"},
      "options" => {},
      "label" => "elephantsql-n/a",
      "provider" => "elephantsql",
      "version" => "n/a",
      "vendor" => "elephantsql",
      "plan" => "panda",
      "plan_option" => "plan_option",
      "name" => "elephantsql-vip-uat",
      "tags" => {"key" => "value"}
    }
  end
  let(:services) { [service] }

  let(:environment) { ["A=b", "C=d"] }
  let(:debug) { nil }

  let(:starting_message) do
    {
      "droplet" => "fake-droplet-sha",
      "tags" => {
        "space" => "fake-space-sha"
      },
      "name" => "vip-uat-sidekiq",
      "uris" => ["first_uri", "second_uri"],
      "prod" => false,
      "sha1" => nil,
      "executableFile" => "deprecated",
      "executableUri" => nil,
      "version" => "fake-version-no",
      "services" => services,
      "limits" => {
        "mem" => 512,
        "disk" => 1024,
        "fds" => 16384},
      "cc_partition" => "default",
      "env" => environment,
      "console" => true,
      "debug" => debug,
      "index" => 0
    }
  end

  context "when running from the instance task" do
    let(:instance) do
      mock(:instance,
        instance_id: VCAP.secure_uuid,
        instance_index: 37,
        state_starting_timestamp: Time.now.to_f,
        instance_container_port: 4567,
        instance_console_container_port: 1234,
        instance_debug_container_port: 2345
      )
    end

    subject(:env) { Dea::Env.new(starting_message, instance) }

    describe "#services_for_json" do
      let(:services_for_json) { env.send(:services_for_json) }

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
      let(:application_for_json) { env.send(:application_for_json) }

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

    describe "#system_environment_variables" do
      def find(key)
        pair = subject.system_environment_variables.find { |e| e[0] == key }
        pair[1] if pair
      end

      it "includes VCAP_APPLICATION" do
        find("VCAP_APPLICATION")["limits"].should be
        find("VCAP_APPLICATION")["application_name"].should be
        find("VCAP_APPLICATION")["start"].should be
      end

      it "includes VCAP_SERVICES" do
        find("VCAP_SERVICES")["name"].should be
        find("VCAP_SERVICES")["label"].should be
        find("VCAP_SERVICES")["tags"].should be
      end

      it "includes VCAP_APP_*" do
        find("VCAP_APP_HOST").should == "'0.0.0.0'"
        find("VCAP_APP_PORT").should == "'4567'"
      end

      it "does not includes VCAP_DEBUG_*" do
        find("VCAP_DEBUG_IP").should be_nil
        find("VCAP_DEBUG_PORT").should be_nil
      end

      it "includes VCAP_CONSOLE_*" do
        find("VCAP_CONSOLE_IP").should == "'0.0.0.0'"
        find("VCAP_CONSOLE_PORT").should == "'1234'"
      end

      it "doesn't include the debug mode when debug mode is not set" do
        instance.stub(:debug).and_return(nil)
        find("VCAP_DEBUG_MODE").should_not be
      end

      it "includes HOME environment var" do
        find("HOME").should == "'$PWD/app'"
      end

      it "includes PORT environment var" do
        find("PORT").should == "'$VCAP_APP_PORT'"
      end

      it "includes MEMORY_LIMIT environment var in MB" do
        find("MEMORY_LIMIT").should == "'512m'"
      end

      it "includes TMPDIR environment var in MB" do
        find("TMPDIR").should == "'$PWD/tmp'"
      end

      context "when it has a DB" do
        it "include a DATABASE_URL" do
          find("DATABASE_URL").should == "'postgresql://user:pass@host:5432/db'"
        end
      end

      context "when it has no DB" do
        let(:services) { [] }

        it "doesn't include DATABASE_URL" do
          find("DATABASE_URL").should be_nil
        end
      end

      context "when debug is set" do
        let(:debug) { 'mode' }

        it "includes the debug mode when the debug mode is set" do
          find("VCAP_DEBUG_MODE").should == "'mode'"
        end

        it "does not includes VCAP_DEBUG_*" do
          find("VCAP_DEBUG_IP").should == "'0.0.0.0'"
          find("VCAP_DEBUG_PORT").should == "'2345'"
        end
      end
    end

    describe "#user_environment_variables" do
      it "includes the user-specified environment in double quotes" do
        expect(subject.user_environment_variables).to eq([['A', '"b"'], ['C', '"d"']])
      end
    end
  end

  context "when running from the staging task" do
    let(:staging_message) do
      {
        "app_id" => "fake-app-id",
        "task_id" => "fake-task-id",
        "properties" => {
          "services" => services,
          "buildpack" => nil,
          "resources" => {
            "memory" => 512,
            "disk" => 1024,
            "fds" => 16384
          },
          "environment" => environment,
          "meta" => {
            "console" => true,
            "command" => "some_command"
          }
        },
        "download_uri" => "https://download_uri",
        "upload_uri" => "http://upload_uri",
        "buildpack_cache_download_uri" => "https://buildpack_cache_download_uri",
        "buildpack_cache_upload_uri" => "http://buildpack_cache_upload_uri",
        "start_message" => starting_message
      }
    end

    subject(:env) { Dea::Env.new(staging_message) }

    describe "#services_for_json" do
      let(:services_for_json) { env.send(:services_for_json) }

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
      let(:application_for_json) { env.send(:application_for_json) }

      it "returns a Hash" do
        application_for_json.should be_a(Hash)
      end

      keys = %W(
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

      it "includes the resource limits" do
        application_for_json["limits"].should be_a(Hash)
      end

      describe "translation" do
        translations = {
          "application_version"  => "version",
          "application_name"     => "name",
          "application_uris"     => "uris",
          "application_users"    => "users",
        }

        translations.each do |from, to|
          it "should translate #{from.inspect} to #{to.inspect}" do
            application_for_json[to].should == application_for_json[from]
          end
        end
      end
    end

    describe "#system_environment_variables" do
      def find(key)
        pair = subject.system_environment_variables.find { |e| e[0] == key }
        pair[1] if pair
      end

      it "includes VCAP_APPLICATION" do
        find("VCAP_APPLICATION")["limits"].should be
        find("VCAP_APPLICATION")["application_name"].should be
        find("VCAP_APPLICATION")["start"].should_not be
      end

      it "includes VCAP_SERVICES" do
        find("VCAP_SERVICES")["name"].should be
        find("VCAP_SERVICES")["label"].should be
        find("VCAP_SERVICES")["tags"].should be
      end

      it "includes HOME environment var" do
        find("HOME").should == "'$PWD/app'"
      end

      it "includes PORT environment var" do
        find("PORT").should == "'$VCAP_APP_PORT'"
      end

      it "includes MEMORY_LIMIT environment var in MB" do
        find("MEMORY_LIMIT").should == "'512m'"
      end

      it "includes TMPDIR environment var in MB" do
        find("TMPDIR").should == "'$PWD/tmp'"
      end

      context "when it has a DB" do
        it "include a DATABASE_URL" do
          find("DATABASE_URL").should == "'postgresql://user:pass@host:5432/db'"
        end
      end

      context "when it has no DB" do
        let(:services) { [] }

        it "doesn't include DATABASE_URL" do
          find("DATABASE_URL").should be_nil
        end
      end
    end

    describe "#user_environment_variables" do
      it "includes the user-specified environment in double quotes" do
        expect(subject.user_environment_variables).to eq([['A', '"b"'], ['C', '"d"']])
      end
    end
  end

  xit "shell escapes the values"
  xit "should write the export or unset string"
end
