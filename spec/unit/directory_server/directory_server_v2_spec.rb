require "spec_helper"
require "dea/directory_server/directory_server_v2"
require "dea/starting/instance_registry"
require "dea/staging/staging_task_registry"

describe Dea::DirectoryServerV2 do
  let(:instance_registry) do
    instance_registry = nil
    with_event_machine do
      instance_registry = Dea::InstanceRegistry.new({})
      done
    end
    instance_registry
  end
  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }

  let(:router_client) { double(:router_client, unregister_directory_server: nil) }
  let(:port) { 1234 }

  let(:config) { {"directory_server" => {"file_api_port" => 3456, "protocol" => "http"}} }
  subject { Dea::DirectoryServerV2.new("domain", port, router_client, config) }

  describe "#initialize" do
    it "sets up hmac helper with correct key" do
      expect(subject.hmac_helper.key).to be_a(String)
    end
  end

  describe "#unregister" do
    it "unregisters from the router client" do
      expect(router_client).to receive(:unregister_directory_server).with(port, subject.external_hostname)
      subject.unregister
    end
  end

  describe "#configure_endpoints" do
    before { subject.configure_endpoints(instance_registry, staging_task_registry) }

    it "sets up file api server" do
      subject.file_api_server.tap do |s|
        expect(s).to be_an_instance_of Thin::Server
        expect(s.host).to eq("127.0.0.1")
        expect(s.port).to eq(3456)
        expect(s.app).to_not be_nil
      end
    end

    it "configures instance paths resource endpoints" do
      expect(Dea::DirectoryServerV2::InstancePaths.global_setting(:directory_server)).to eq(subject)
      expect(Dea::DirectoryServerV2::InstancePaths.global_setting(:instance_registry)).to eq(instance_registry)
      expect(Dea::DirectoryServerV2::InstancePaths.global_setting(:max_url_age_secs)).to eq(3600)
    end

    it "configures staging tasks resource endpoints" do
      expect(Dea::DirectoryServerV2::StagingTasks.global_setting(:directory_server)).to eq(subject)
      expect(Dea::DirectoryServerV2::StagingTasks.global_setting(:staging_task_registry)).to eq(staging_task_registry)
      expect(Dea::DirectoryServerV2::StagingTasks.global_setting(:max_url_age_secs)).to eq(3600)
    end
  end

  describe "#start" do
    context "when file api server was configured" do
      before { subject.configure_endpoints(instance_registry, staging_task_registry) }

      # For debugging you can do 'Thin::Logging.silent = false'
      def make_request(url)
        response = nil
        with_event_machine(:timeout => 1) do
          subject.start

          http = EM::HttpRequest.new(url).get
          on_response = lambda do |*args|
            response = http.response
            done
          end

          http.errback(&on_response)
          http.callback(&on_response)
        end
        response
      end

      def localize_url(url)
        url.sub(subject.external_hostname, "127.0.0.1:3456")
      end

      it "can handle instance paths requests" do
        url = subject.instance_file_url_for("instance-id", "some-file-path")
        response = make_request(localize_url(url))
        expect(response).to include("Unknown instance")
      end

      it "can handle staging tasks requests" do
        url = subject.staging_task_file_url_for("task-id", "some-file-path")
        response = make_request(localize_url(url))
        expect(response).to include("Unknown staging task")
      end
    end

    context "when file api server was not configured" do
      it "starts the file api server" do
        expect {
          subject.start
        }.to raise_error(ArgumentError, /file api server must be configured/)
      end
    end
  end

  describe "url generation" do
    def self.it_generates_url(path)
      it "includes external host" do
        expect(url).to start_with("#{config["directory_server"]["protocol"]}://#{subject.uuid}.domain")
      end

      it "includes path" do
        expect(url).to include(".domain#{path}")
      end
    end

    def self.it_hmacs_url(path_and_query)
      it "includes generated hmac param" do
        expect(subject.hmac_helper).to receive(:create).with(path_and_query).and_return("hmac-value")
        expect(url).to include("hmac=hmac-value")
      end
    end

    def query_params(url)
      Rack::Utils.parse_query(URI.parse(url).query)
    end

    describe "#hmaced_url_for" do
      let(:config) { {"directory_server" => {"protocol" => "FAKEPROTOCOL"}} }
      let(:url) { subject.hmaced_url_for("/path", {:param => "value"}, [:param]) }

      it_generates_url "/path"
      it_hmacs_url "/path?param=value"

      it "includes given params" do
        expect(query_params(url)["param"]).to eq("value")
      end

      it "takes protocol from config" do
        expect(url).to match(%r{^FAKEPROTOCOL://})
      end
    end

    describe "#instance_file_url_for" do
      let(:url) { subject.instance_file_url_for("instance-id", "/path-to-file") }
      before { allow(Time).to receive(:now).and_return(Time.at(10)) }

      it_generates_url "/instance_paths/instance-id"
      it_hmacs_url "/instance_paths/instance-id?path=%2Fpath-to-file&timestamp=10"

      it "includes timestamp with current time" do
        expect(query_params(url)["timestamp"]).to eq("10")
      end

      it "includes file path" do
        expect(query_params(url)["path"]).to eq("/path-to-file")
      end
    end

    describe "#staging_task_file_url_for" do
      let(:url) { subject.staging_task_file_url_for("task-id", "/path-to-file") }
      before { allow(Time).to receive(:now).and_return(Time.at(10)) }

      it_generates_url "/staging_tasks/task-id/file_path"
      it_hmacs_url "/staging_tasks/task-id/file_path?path=%2Fpath-to-file&timestamp=10"

      it "includes timestamp with current time" do
        expect(query_params(url)["timestamp"]).to eq("10")
      end

      it "includes file path" do
        expect(query_params(url)["path"]).to eq("/path-to-file")
      end
    end
  end

  describe "#verify_hmaced_url" do
    context "when hmac-ed path matches original path" do
      let(:verified_params) { [] }
      let(:url) { subject.hmaced_url_for("/path", {:param => "value"}, verified_params) }

      it "returns true" do
        expect(subject.verify_hmaced_url(url, verified_params)).to be true
      end
    end

    context "when path does not match original path" do
      let(:verified_params) { [] }
      let(:url) { subject.hmaced_url_for("/path", {:param => "value"}, verified_params) }

      it "returns false" do
        url.sub!("/path", "/malicious-path")
        expect(subject.verify_hmaced_url(url, verified_params)).to be false
      end
    end

    context "when hmac-ed params match original params" do
      let(:url) { subject.hmaced_url_for("/path", {:param1 => "value1", :param2 => "value2"}, verified_params) }

      context "when verifying all params" do
        let(:verified_params) { [:param1, :param2] }

        it "returns true" do
          expect(subject.verify_hmaced_url(url, verified_params)).to be true
        end
      end

      context "when verifying specific params" do
        let(:verified_params) { [:param1] }

        it "returns true" do
          expect(subject.verify_hmaced_url(url, verified_params)).to be true
        end
      end
    end

    context "when hmac-ed params are reordered" do
      let(:verified_params) { [:param1, :param2] }
      let(:url) { subject.hmaced_url_for("/path", {:param1 => "value", :param2 => "value"}, verified_params) }

      it "returns true" do
        url.sub!("param1", "paramX")
        url.sub!("param2", "param1")
        url.sub!("paramX", "param2")

        expect(subject.verify_hmaced_url(url, verified_params)).to be true
      end
    end

    context "when hmac-ed param does not match original param" do
      let(:verified_params) { [:param] }
      let(:url) { subject.hmaced_url_for("/path", {:param => "value"}, verified_params) }

      it "returns false" do
        url.sub!("value", "malicious-value")
        expect(subject.verify_hmaced_url(url, verified_params)).to be false
      end
    end

    context "when non-hmac-ed param is added (to support misc params additions)" do
      let(:verified_params) { [:param] }
      let(:url) { subject.hmaced_url_for("/path", {:param => "value"}, verified_params) }

      it "returns true" do
        url << "&new_param=new-value"
        expect(subject.verify_hmaced_url(url, verified_params)).to be true
      end
    end

    context "when url does not have hmac param" do
      it "returns false" do
        expect(subject.verify_hmaced_url("http://google.com", [])).to be false
      end
    end

    context "when passed url is not a valid url" do
      it "returns false" do
        expect(subject.verify_hmaced_url("invalid-url", [])).to be false
      end
    end
  end
end
