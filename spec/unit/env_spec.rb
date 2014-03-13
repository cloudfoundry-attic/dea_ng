# coding: UTF-8

require "spec_helper"
require "vcap/common"
require "dea/env"
require "dea/starting/start_message"
require "dea/staging/staging_message"

describe Dea::Env do
  class NullEnvExporter < Struct.new(:variables)
    def export
      variables.inject({}) {|h, a| h[a[0]] = a[1]; h }
    end
  end

  let(:env_exporter) { NullEnvExporter }

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
      "tags" => {"key" => "value"},
      "syslog_drain_url" => "syslog://drain-url.example.com:514"
    }
  end

  let(:services) { [service] }

  let(:user_provided_environment) { ["fake_user_provided_key=fake_user_provided_value"] }

  let(:instance) do
    attributes = {"instance_id" => VCAP.secure_uuid}
    double(:instance, attributes: attributes, instance_container_port: 4567, state_starting_timestamp: Time.now.to_f)
  end

  let(:start_message) { StartMessage.new(starting_message) }

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
      "env" => user_provided_environment,
      "index" => 0
    }
  end

  context "when running from the starting (instance) task" do
    subject(:env) { Dea::Env.new(start_message, instance, env_exporter) }

    its(:strategy_env) { should be_an_instance_of Dea::RunningEnv }

    describe "#vcap_services" do
      let(:vcap_services) { env.send(:vcap_services) }

      keys = %W(
        name
        label
        tags
        plan
        plan_option
        credentials
        syslog_drain_url
      )

      keys.each do |key|
        it "includes #{key.inspect}" do
          vcap_services[service["label"]].first.should include(key)
        end
      end

      it "doesn't include unknown keys" do
        vcap_services[service["label"]].should have(1).service
        vcap_services[service["label"]].first.keys.should_not include("invalid")
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
          vcap_services.should have(2).groups
          vcap_services["l1"].should have(2).services
          vcap_services["l2"].should have(1).service
        end
      end

      describe "ignoring" do
        let(:services) do
          [service.merge("name" => nil)]
        end

        it "should ignore keys with nil values" do
          vcap_services[service["label"]].should have(1).service
          vcap_services[service["label"]].first.keys.should_not include("name")
        end
      end
    end

    describe "#vcap_application" do
      let(:vcap_application) { env.send(:vcap_application) }

      it "returns a Hash" do
        vcap_application.should be_a(Hash)
      end

      keys = %W[
        instance_id
        instance_index
        application_version
        application_name
        application_uris
      ]

      keys.each do |key|
        it "includes #{key.inspect}" do
          vcap_application.should include(key)
        end
      end

      it "includes the time the instance was started" do
        vcap_application["started_at"].should be_a(Time)
        vcap_application["started_at_timestamp"].should be_a(Integer)
      end

      it "includes the host and port the instance should listen on" do
        vcap_application["host"].should be
        vcap_application["port"].should == 4567
      end

      it "includes the resource limits" do
        vcap_application["limits"].should be_a(Hash)
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
            vcap_application[to].should == vcap_application[from]
          end
        end
      end
    end

    describe "#exported_system_environment_variables" do
      let(:exported_system_vars) { env.exported_system_environment_variables }

      it "exports VCAP_APPLICATION" do
        exported_system_vars["VCAP_APPLICATION"].should match(%r{\"instance_index\":0})
      end

      it "exports VCAP_SERVICES" do
        exported_system_vars["VCAP_SERVICES"].should match(%r{\"plan\":\"panda\"})
      end

      it "exports VCAP_APP_HOST" do
        exported_system_vars["VCAP_APP_HOST"].should match("0.0.0.0")
      end

      it "exports VCAP_APP_PORT" do
        exported_system_vars["VCAP_APP_PORT"].should eql(4567)
      end

      it "does not export VCAP_DEBUG_IP" do
        exported_system_vars.should_not have_key("VCAP_DEBUG_IP")
      end

      it "does not export VCAP_DEBUG_PORT" do
        exported_system_vars.should_not have_key("VCAP_DEBUG_PORT")
      end

      it "exports PORT" do
        exported_system_vars["PORT"].should eql("$VCAP_APP_PORT")
      end

      it "exports MEMORY_LIMIT" do
        exported_system_vars["MEMORY_LIMIT"].should match("512m")
      end

      it "exports HOME" do
        exported_system_vars["HOME"].should eql("$PWD/app")
      end

      it "exports TMPDIR" do
        exported_system_vars["TMPDIR"].should eql("$PWD/tmp")
      end

      context "when it has a DB" do
        it "exports DATABASE_URL" do
          exported_system_vars["DATABASE_URL"].should match("postgres://user:pass@host:5432/db")
        end
      end

      context "when it does NOT have a DB" do
        let(:services) { [] }

        it "does not export DATABASE_URL" do
          exported_system_vars.should_not have_key("DATABASE_URL")
        end
      end
    end

    describe "#exported_user_environment_variables" do
      let(:exported_variables) { env.exported_user_environment_variables }

      it "includes the user defined variables" do
        exported_variables["fake_user_provided_key"].should match("fake_user_provided_value")
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
          "environment" => user_provided_environment,
          "meta" => {
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

    let(:staging_task) do
      staging_task = double(:staging_task)
      staging_task.stub(:is_a?).with(Dea::StagingTask) { true }
      staging_task.stub(:staging_config) { {"environment" => {"BUILDPACK_CACHE" => ""}} }
      staging_task.stub(:staging_timeout) { 900 }
      staging_task
    end

    subject(:env) { Dea::Env.new(StagingMessage.new(staging_message), staging_task, env_exporter) }

    its(:strategy_env) { should be_an_instance_of Dea::StagingEnv }

    describe "#vcap_services" do
      let(:vcap_services) { env.send(:vcap_services) }

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
          vcap_services[service["label"]].first.should include(key)
        end
      end

      it "doesn't include unknown keys" do
        vcap_services[service["label"]].should have(1).service
        vcap_services[service["label"]].first.keys.should_not include("invalid")
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
          vcap_services.should have(2).groups
          vcap_services["l1"].should have(2).services
          vcap_services["l2"].should have(1).service
        end
      end

      describe "ignoring" do
        let(:services) do
          [service.merge("name" => nil)]
        end

        it "should ignore keys with nil values" do
          vcap_services[service["label"]].should have(1).service
          vcap_services[service["label"]].first.keys.should_not include("name")
        end
      end
    end

    describe "#vcap_application" do
      let(:vcap_application) { env.send(:vcap_application) }

      it "returns a Hash" do
        vcap_application.should be_a(Hash)
      end

      keys = %W[
        application_version
        application_name
        application_uris
      ]

      keys.each do |key|
        it "includes #{key.inspect}" do
          vcap_application.should include(key)
        end
      end

      it "includes the resource limits" do
        vcap_application["limits"].should be_a(Hash)
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
            vcap_application[to].should == vcap_application[from]
          end
        end
      end
    end

    describe "#exported_system_environment_variables" do
      let(:exported_variables) { env.exported_system_environment_variables }

      it "exports VCAP_APPLICATION" do
        exported_variables["VCAP_APPLICATION"].should match(%r{\"mem\":512})
      end
      it "exports VCAP_SERVICES" do
        exported_variables["VCAP_SERVICES"].should match(%r{\"plan\":\"panda\"})
      end
      it "exports MEMORY_LIMIT" do
        exported_variables["MEMORY_LIMIT"].should match("512m")
      end

      context "when it has a DB" do
        it "exports DATABASE_URL" do
          exported_variables["DATABASE_URL"].should match("postgres://user:pass@host:5432/db")
        end
      end

      context "when it does NOT have a DB" do
        let(:services) { [] }

        it "does not exports DATABASE_URL" do
          exported_variables.should_not have_key("DATABASE_URL")
        end
      end
    end

    describe "#user_environment_variables" do
      let(:exported_variables) { env.exported_user_environment_variables }

      it "includes the user defined variables" do
        exported_variables["fake_user_provided_key"].should match("fake_user_provided_value")
      end
    end
  end

  describe "exported_environment_variables" do
    let(:user_provided_environment) { ["PORT=stupid idea"] }
    subject(:env) { Dea::Env.new(start_message, instance, env_exporter) }

    it "exports PORT" do
      env.exported_environment_variables["PORT"].should match("stupid idea")
    end
  end
end
