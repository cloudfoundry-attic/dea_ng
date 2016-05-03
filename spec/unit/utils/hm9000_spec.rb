require 'spec_helper'
require 'dea/utils/hm9000'
require 'dea/protocol'

describe HM9000 do
  around do |example|
    with_event_machine { example.call }
  end

  let(:to_uri) { URI("https://a.b.c.d:12345/") }

  let(:polling_timeout_in_second) { 3 }
  let(:timeout) { 10 }

  subject { HM9000.new(
    to_uri,
    fixture('/certs/hm9000_client.key'),
    fixture('/certs/hm9000_client.cert'),
    fixture('/certs/hm9000_client.crt'),
    timeout,
  )}

  before do
    allow(EM).to receive(:defer) do |operation, &_|
      operation.call
    end
  end

  describe "#send_heartbeat" do
    let(:heartbeat) { Dea::Protocol::V1::HeartbeatResponse.generate("dea-uuid", []) }

    before { WebMock.disable_net_connect! }

    context 'when the request succeeds' do
      before do
        stub_request(:post, "https://a.b.c.d:12345/dea/heartbeat").with(:body => '{"droplets":[],"dea":"dea-uuid"}').to_return(:status => status)
      end

      context 'when the status is 202' do
        let(:status) {202}

        it "creates the correct request with the heartbeat in json" do
          subject.send_heartbeat(heartbeat) do |response|
            expect(response.status).to eq(status)
            done
          end
        end
      end

      context 'when the status is not 202' do
        let(:status) {401}

        it 'returns the status' do
          subject.send_heartbeat(heartbeat) do |response|
            expect(response.status).to eq(status)
            done
          end
        end
      end
    end

    context 'when the request raises an exception' do
      before { WebMock.allow_net_connect! }

      it 'reports the error' do
        expect(subject.logger).to receive(:error).with('hm9000.heartbeat.failed', hash_including(:error))
        subject.send_heartbeat(heartbeat)
        done
      end
    end
  end
end
