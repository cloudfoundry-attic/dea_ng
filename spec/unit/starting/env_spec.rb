require "spec_helper"
require "dea/starting/env"
require "dea/starting/start_message"
require "dea/starting/instance"

module Dea::Starting
  describe Env do
    subject(:env) {Env.new(message, instance)}
    let(:message) { instance_double("StartMessage") }
    let(:config) { {"instance" => ""} }
    let(:instance) do
      instance_double("Dea::Instance", instance_container_port: "fake_port", config: config)
    end

    describe "system environment variables" do
      subject(:system_environment_variables) { env.system_environment_variables }

      it "has the correct values" do
        expect(system_environment_variables).to eql([
                                                      %w(HOME $PWD/app),
                                                      %w(TMPDIR $PWD/tmp),
                                                      %w(VCAP_APP_HOST 0.0.0.0),
                                                      %w(VCAP_APP_PORT fake_port),
                                                      %w(PORT $VCAP_APP_PORT)
                                                    ])
      end

      context "when setting proxy" do
        let(:config) {
          {
              "instance" =>
                  {
                      "http_proxy" => "http://user:password@1.2.3.4:8080/",
                      "https_proxy" => "https://user:password@1.2.3.4:8080/",
                      "no_proxy" => "localhost,127.0.0.1" 
                  }
          }
        }
        it "can get the proxy correctly" do
          expect(system_environment_variables).to eql([
                                                          %w(HOME $PWD/app),
                                                          %w(TMPDIR $PWD/tmp),
                                                          %w(VCAP_APP_HOST 0.0.0.0),
                                                          %w(VCAP_APP_PORT fake_port),
                                                          %w(PORT $VCAP_APP_PORT),
                                                          %w(http_proxy http://user:password@1.2.3.4:8080/) ,
                                                          %w(https_proxy https://user:password@1.2.3.4:8080/),
                                                          %w(no_proxy localhost,127.0.0.1)
                                                      ])
        end
      end
    end

    describe "vcap_application" do
      subject(:vcap_application) { env.vcap_application }
      let(:start_timestamp) { Time.now.to_i }
      let(:attributes) do
        {
          "application_id" => "fake application id",
          "instance_id" => "fake instance id",
        }
      end

      before do
        allow(instance).to receive(:attributes).and_return(attributes)
        allow(instance).to receive(:instance_container_port).and_return("fake port")
        allow(instance).to receive(:state_starting_timestamp).and_return(start_timestamp)
        allow(message).to receive(:index).and_return("fake instance index")
      end

      it "has the correct values" do
        expect(vcap_application).to eql(
          "application_id" => "fake application id",
          "instance_id" => "fake instance id",
          "instance_index" => "fake instance index",
          "host" => "0.0.0.0",
          "port" => "fake port",
          "started_at" => Time.at(start_timestamp),
          "started_at_timestamp" => Time.at(start_timestamp).to_i,
          "start" => Time.at(start_timestamp),
          "state_timestamp" => Time.at(start_timestamp).to_i,
        )
      end
    end

    it "has a message" do
      expect(env.message).to eql(message)
    end

    it "has an instance" do
      expect(env.instance).to eql(instance)
    end
  end
end
