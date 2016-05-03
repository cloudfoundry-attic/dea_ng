require 'spec_helper'
require 'dea/utils/cloud_controller_client'
require 'dea/protocol'

module Dea
  describe CloudControllerClient do
    around do |example|
      with_event_machine { example.call }
    end


    let(:polling_timeout_in_second) { 3 }
    let(:logger) { double(:logger, info: nil, warn: nil, debug: nil) }

    let(:response) {
      {
        task_id: 'taskid',
        detected_buildpack: 'test_buildback',
        buildpack_key: 'asdf',
        droplet_sha1: 'qwer',
        detected_start_command: '/usr/bin/do_stuff',
        procfile: 'a_procfile',
        app_id: 'asdf-qwer-zxcv'
      }
    }

    let(:cc_uri) { 'http://127.0.0.1:12345' }
    let(:to_uri) { "#{cc_uri}/internal/dea/staging/#{response[:app_id]}/completed" }

    subject { CloudControllerClient.new(cc_uri, logger) }

    describe "#send_staging_response" do
      let(:request) { double(:request, method: 'post').as_null_object }
      let(:http) { double(:http, req: request).as_null_object }

      let(:status) { 200 }

      context "when everything works perfectly" do
        let(:http) { double(:http, req: request, response_header: { status: status }).as_null_object }
        it "logs the success" do
          expect(EM::HttpRequest).to receive(:new).with(to_uri, inactivity_timeout: 300).and_return(http)
          expect(http).to receive(:post).with(
                            head: { 'content-type' => 'application/json' },
                            body: Yajl::Encoder.encode(response)
                          )
          expect(subject.logger).to receive(:info).with('cloud_controller.staging_response.sending', hash_including(:destination))
          expect(http).to receive(:callback)
          expect(http).to receive(:errback)

          subject.send_staging_response(response)

          done
        end
      end
    end
  end
end
