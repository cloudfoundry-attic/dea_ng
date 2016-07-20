require "spec_helper"
require "dea/http/httpserver"
require "dea/bootstrap"

describe Dea::Http do
  let(:bootstrap) { double(Dea::Bootstrap, :evac_handler => evac_handler, :shutdown_handler => shutdown_handler) }
  let(:evac_handler) { double(EvacuationHandler, :evacuating? => false) }
  let(:shutdown_handler) { double(ShutdownHandler, :shutting_down? => false) }
  let(:port) { 1234 }

  let(:config) {
    { "ssl" => {
        "port" => port,
        "key_file" => fixture("certs/server.key"),
        "cert_file" => fixture("certs/server.crt"),
      }
    }
  }
  subject { Dea::HttpServer.new(bootstrap, config) }

  describe "#initialize" do
    it "sets up http server" do
      subject.http_server.tap do |s|
        expect(s).to be_an_instance_of Thin::Server
        expect(s.host).to eq('0.0.0.0')
        expect(s.port).to eq(port)
        expect(s.app).to_not be_nil
      end
    end

    it "configures app paths" do
      subject
      expect(Dea::Http::AppPaths.global_setting(:bootstrap)).to eq(bootstrap)
    end

    it 'is enabled' do
      expect(subject.enabled?).to be_truthy
    end

    context "when the port is not configured" do
      let(:config) { {"ssl" => {}} }

      it "raises an error" do
        expect {
          subject
        }.to raise_error(ArgumentError, /port must be configured/)
      end
    end

    context 'with no ssl config' do
      let(:config) { {} }

      it 'is not enabled' do
        expect(subject.enabled?).to be_falsey
      end
    end
  end

  describe "#start" do
    let(:options) {{
      :ssl => {
        :verify_peer => false 
        # this is false because the certs need a valid domain. Not sure we can verify this here because of a localhost domain
        # :private_key_file => fixture("certs/client.key"),
        # :cert_chain_file => fixture("certs/client.crt"),
      }
    }}

    # For debugging you can do 'Thin::Logging.silent = false'
    def make_request(url)
      response = nil
      with_event_machine(:timeout => 1) do
        subject.start

        http = EM::HttpRequest.new(url, options).post
        on_response = lambda do |*args|
          response = http.response
          done
        end

        http.errback(&on_response)
        http.callback(&on_response)
      end
      response
    end

    it "can handle app paths requests" do
      allow(bootstrap).to receive(:start_app)

      response = make_request("https://127.0.0.1:#{port}/v1/apps")
      expect(response).to include("202")
    end

    it "can handle stage path requests" do
      allow(bootstrap).to receive(:stage_app_request)

      response = make_request("https://127.0.0.1:#{port}/v1/stage")
      expect(response).to include("202")
    end
  end
end
