require 'spec_helper'
require 'dea/utils/cloud_controller_client'
require 'thin'

module Dea
  describe CloudControllerClient do
    around do |example|
      with_event_machine(timeout: 20) { example.call }
    end

    let(:uuid) { 'dea_id' }
    let(:cc_uri) { "http://127.0.0.1:#{port}" }
    let(:to_uri) { "#{cc_uri}/internal/dea/staging/#{response[:app_id]}/completed" }
    subject { CloudControllerClient.new(uuid, cc_uri, nil) }

    let(:response) {
      {
        task_id: 'taskid',
        detected_buildpack: 'test_buildback',
        buildpack_key: 'asdf',
        droplet_sha1: 'qwer',
        detected_start_command: '/usr/bin/do_stuff',
        procfile: 'a_procfile',
        app_id: 'asdf-qwer-zxcv',
      }
    }
    let(:expected_response) { response.merge( {:dea_id => 'dea_id'} ) }

    let(:port) { 25432 }
    def http_server(response_code)
      Thin::Server.new('0.0.0.0', 25432, lambda do |env|
        @counter += 1
        [response_code,          # Status code
         {             # Response headers
          'Content-Type' => 'text/html',
          'Content-Length' => '2',
        },
        ['hi']]
      end)
    end

    describe "#send_staging_response" do
      context "when everything works perfectly" do
        let(:request) { double(:request, method: 'post').as_null_object }
        let(:http) { double(:http, req: request, response_header: { status: status }).as_null_object }
        let(:status) { 200 }

        it "logs the success" do
          expect(EM::HttpRequest).to receive(:new).with(URI.parse(to_uri), inactivity_timeout: 30).and_return(http)
          expect(http).to receive(:post).with(
            head: { 'content-type' => 'application/json' },
            body: Yajl::Encoder.encode(expected_response)
          )
          expect(subject.logger).to receive(:info)
          expect(http).to receive(:callback)
          expect(http).to receive(:errback)

          subject.send_staging_response(response)

          done
        end
      end

      context 'when we receive a 200' do
        before do
          @counter = 0
          http_server(200).start
        end

        it 'calls the completion_callback' do
          subject.send_staging_response(response) do
            expect(@counter).to eq 1
            done
          end
        end
      end

      context 'when we receive an error code 500 back' do
        before do
          http_server(500).start
          @counter = 0
        end

        it 'retries up to 3 times' do
          subject.send_staging_response(response) do |iteration|
            # 4 because we star at index 1 and we want to run with 1, 2. 3
            expect(@counter).to eq(3)
            done
          end
        end
      end

      context 'when the server returns a 404' do
        before do
          # if the server is not running eventmachine gives us a status code of
          # 0, but only in test.
          http_server(404).start
          @counter = 0
        end

        it 'retries up to 3 times' do
          subject.send_staging_response(response) do |iteration|
            # 4 because we star at index 1 and we want to run with 1, 2. 3
            expect(@counter).to eq(3)
            done
          end
        end
      end
    end
  end
end
