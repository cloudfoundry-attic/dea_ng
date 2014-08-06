require "spec_helper"
require "dea/staging/env"

module Dea::Staging
  describe Env do
    let(:start_message) { double("message", mem_limit: "fake_mem_limit") }
    let(:staging_message) { double("staging message", start_message: start_message) }
    let(:staging_config) {
      { "environment" => { "BUILDPACK_CACHE" => "fake_buildpack_cache" } }
    }
    let(:task) { double("task", staging_config: staging_config, staging_timeout: "fake_timeout") }

    subject(:env) {Env.new(staging_message, task)}

    describe "system environment variables" do
      subject(:system_environment_variables) { env.system_environment_variables }

      it "has the correct values" do
        expect(system_environment_variables).to eql([
                                                      %w(BUILDPACK_CACHE fake_buildpack_cache),
                                                      %w(STAGING_TIMEOUT fake_timeout),
                                                      %w(MEMORY_LIMIT fake_mem_limitm),
                                                    ])
      end

      context "when setting proxy" do
          let(:staging_config) {
            {
                "http_proxy" => "http://user:password@1.2.3.4:8080/",
                "https_proxy" => "https://user:password@1.2.3.4:8080/",
                "no_proxy" => "localhost,127.0.0.1",
                "environment" => { "BUILDPACK_CACHE" => "fake_buildpack_cache" }
            }
          }
          it "can get the proxy correctly" do
            expect(system_environment_variables).to eql([
                                                            %w(BUILDPACK_CACHE fake_buildpack_cache),
                                                            %w(STAGING_TIMEOUT fake_timeout),
                                                            %w(MEMORY_LIMIT fake_mem_limitm),
                                                            %w(http_proxy http://user:password@1.2.3.4:8080/) ,
                                                            %w(https_proxy https://user:password@1.2.3.4:8080/),
                                                            %w(no_proxy localhost,127.0.0.1),
                                                        ])
          end
      end
    end

    describe "vcap_application" do
      subject(:vcap_application) { env.vcap_application }
      it "is empty" do
        expect(vcap_application).to eql({})
      end
    end

    it "has a message" do
      expect(env.message).to eql(start_message)
    end

    it "has an instance" do
      expect(env.staging_task).to eql(task)
    end
  end
end


