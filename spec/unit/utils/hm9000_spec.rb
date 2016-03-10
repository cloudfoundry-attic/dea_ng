require 'spec_helper'
require 'dea/utils/hm9000'
require 'dea/protocol'

describe HM9000 do
  around do |example|
    with_event_machine { example.call }
  end

  let(:to_uri) { URI("http://127.0.0.1:12345/") }

  let(:polling_timeout_in_second) { 3 }
  let(:logger) { double(:logger, info: nil, warn: nil, debug: nil) }

  subject { HM9000.new(to_uri, logger) }

  describe "#send_heartbeat" do
    let(:request) { double(:request, method: 'delete').as_null_object }
    let(:http) { double(:http, req: request).as_null_object }

    let(:heartbeat) { Dea::Protocol::V1::HeartbeatResponse.generate("dea-uuid", []) }

    let(:status) { 202 }

    it "creates the correct request with the heartbeat in json" do
      expect(EM::HttpRequest).to receive(:new).with(to_uri, inactivity_timeout: 300).and_return(http)
      expect(http).to receive(:post).with(
                          body: Yajl::Encoder.encode(heartbeat)
                      )
      expect(http).to receive(:callback)

      subject.send_heartbeat(heartbeat)

      done
    end

    context "when everything works perfectly" do
      let(:http) { double(:http, req: request, response_header: { status: 202 } ).as_null_object }
      it "logs the success" do
        expect(EM::HttpRequest).to receive(:new).with(to_uri, inactivity_timeout: 300).and_return(http)

        expect(subject.logger).to receive(:info)
        expect(http).to receive(:callback)
        expect(http).to receive(:errback)

        subject.send_heartbeat(heartbeat)

        done
      end
    end
  end

  describe '#handle_http_response' do
    let(:response_header) { double(:response_header, status: status)}
    let(:http) { double(:http, req: nil, response_header: response_header ).as_null_object }
    context 'when status is 202' do
      let(:status) { 202 }
      it 'logs the success' do
        expect(subject.logger).to receive(:debug)
        subject.handle_http_response(http)

        done
      end
    end

    context 'when status is not 202' do
      let(:status) { 401 }
      it 'calls handle_error' do
        expect(subject).to receive(:handle_error)

        subject.handle_http_response(http)

        done
      end
    end
  end

  describe '#handle_error' do
    let(:status) { 0 }
    let(:response_header) { double(:response_header, status: status)}
    let(:http) { double(:http, req: nil, response_header: response_header ).as_null_object }
    it 'logs the error' do
      expect(subject.logger).to receive(:warn)
      subject.handle_error(http)

      done
    end
  end
end
