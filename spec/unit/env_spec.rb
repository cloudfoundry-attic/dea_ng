# coding: UTF-8

require "spec_helper"
require "dea/env"
require "dea/starting/start_message"
require "dea/staging/staging_message"

describe Dea::Env do
  class NullExporter < Struct.new(:variables)
    def export
      variables.inject({}) { |h, a| h[a[0]] = a[1]; h }
    end
  end

  let(:strategy) do
    double("strategy",
           vcap_application: {"fake vcap_application key" => "fake vcap_application value"},
           message: start_message,
           system_environment_variables: [%w(fake_key fake_value)]
    )
  end

  let(:strategy_chooser) { double("strategy chooser", strategy: strategy) }

  let(:env_exporter) { NullExporter }

  let(:service) do
    {
      "credentials" => {"uri" => "postgres://user:pass@host:5432/db"},
      "label" => "elephantsql-n/a",
      "plan" => "panda",
      "plan_option" => "plan_option",
      "name" => "elephantsql-vip-uat",
      "tags" => {"key" => "value"},
      "syslog_drain_url" => "syslog://drain-url.example.com:514",
      "blacklisted" => "blacklisted"
    }
  end

  let(:services) { [service] }

  let(:user_provided_environment) { ["fake_user_provided_key=fake_user_provided_value"] }

  let(:instance) do
    attributes = {"instance_id" => Dea.secure_uuid}
    instance_double(
      "Dea::Instance",
      attributes: attributes,
      instance_container_port: 4567,
      state_starting_timestamp: Time.now.to_f,
      instance_host_port: "fake_external_port",
      bootstrap: double(:bootstrap, local_ip: "fake_ip")
    )
  end

  let(:start_message) do
    StartMessage.new(
      "services" => services,
      "limits" => {
        "mem" => 512,
      },
      "vcap_application" => {
        "message vcap_application key" => "message vcap_application value",
      },
      "env" => user_provided_environment,
    )
  end

  subject(:env) { Dea::Env.new(start_message, instance, env_exporter, strategy_chooser) }

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
        expect(vcap_services[service["label"]].first).to include(key)
      end
    end

    it "doesn't include unknown keys" do
      expect(service).to have_key("blacklisted")
      expect(vcap_services[service["label"]].first.keys).to_not include("blacklisted")
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
        expect(vcap_services.size).to eq(2)
        expect(vcap_services["l1"].size).to eq(2)
        expect(vcap_services["l2"].size).to eq(1)
      end
    end

    describe "ignoring" do
      let(:services) do
        [service.merge("name" => nil)]
      end

      it "should ignore keys with nil values" do
        expect(vcap_services[service["label"]].size).to eq(1)
        expect(vcap_services[service["label"]].first.keys).to_not include("name")
      end
    end
  end

  describe "#exported_system_environment_variables" do
    let(:exported_system_vars) { env.exported_system_environment_variables }

    it "includes the system_environment_variables from the strategy" do
      expect(exported_system_vars["fake_key"]).to match("fake_value")
    end

    it "exports MEMORY_LIMIT" do
      expect(exported_system_vars["MEMORY_LIMIT"]).to match("512m")
    end

    it "exports VCAP_APPLICATION containing strategy vcap_application" do
      expect(exported_system_vars["VCAP_APPLICATION"]).to match('"fake vcap_application key":"fake vcap_application value"')
    end

    it "exports VCAP_APPLICATION containing message vcap_application" do
      expect(exported_system_vars["VCAP_APPLICATION"]).to match('"message vcap_application key":"message vcap_application value"')
    end

    it "exports VCAP_SERVICES" do
      expect(exported_system_vars["VCAP_SERVICES"]).to match(%r{\"plan\":\"panda\"})
    end

    context "when it has a DB" do
      it "exports DATABASE_URL" do
        expect(exported_system_vars["DATABASE_URL"]).to match("postgres://user:pass@host:5432/db")
      end
    end

    context "when it does NOT have a DB" do
      let(:services) { [] }

      it "does not export DATABASE_URL" do
        expect(exported_system_vars).to_not have_key("DATABASE_URL")
      end
    end
  end

  describe "#exported_user_environment_variables" do
    let(:exported_variables) { env.exported_user_environment_variables }

    it "includes the user defined variables" do
      expect(exported_variables["fake_user_provided_key"]).to match("fake_user_provided_value")
    end
  end

  describe "exported_environment_variables" do
    let(:user_provided_environment) { ["PORT=stupid idea"] }
    subject(:env) { Dea::Env.new(start_message, instance, env_exporter) }

    it "exports PORT" do
      expect(env.exported_environment_variables["PORT"]).to match("stupid idea")
    end
  end
end
