# coding: UTF-8

require "spec_helper"
require "json"
require "rack/test"

require "dea/directory_server/directory_server_v2"

require "dea/staging/staging_task"
require "dea/staging/staging_task_registry"

describe Dea::DirectoryServerV2::StagingTasks do
  include Rack::Test::Methods
  include_context "tmpdir"

  let(:bootstrap) { double(:bootstrap, :config => {}) }
  let(:directory_server) { Dea::DirectoryServerV2.new("example.org", 1234, nil, {"directory_server" => {"protocol" => "http"}}) }

  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }
  let(:staging_task) { Dea::StagingTask.new(bootstrap, directory_server, StagingMessage.new(valid_staging_attributes), []) }

  before { Dea::DirectoryServerV2::StagingTasks.configure(directory_server, staging_task_registry, 1) }

  describe "GET /staging_tasks/<task_id>/file_path" do
    context "when hmac is missing" do
      it "returns a 401" do
        get staging_task_file_path(staging_task.task_id, "file-path", :hmac => "") + "&path=application&timestamp=0"
        expect(last_response.status).to eq(401)
        expect(last_error).to eq("Invalid HMAC")
      end
    end

    context "when hmac is invalid" do
      it "returns a 401" do
        get staging_task_file_path(staging_task.task_id, "file-path", :hmac => "some-other-hmac") + "&path=application&timestamp=0"
        expect(last_response.status).to eq(401)
        expect(last_error).to eq("Invalid HMAC")
      end
    end

    context "when url has expired" do
      it "returns a 400" do
        allow(Time).to receive(:now).and_return(Time.at(10))
        url = staging_task_file_path(staging_task.task_id, "file-path")

        allow(Time).to receive(:now).and_return(Time.at(12))
        get url

        expect(last_response.status).to eq(400)
        expect(last_error).to eq("Url expired")
      end
    end

    context "when staging task does not exist" do
      it "returns a 404" do
        get staging_task_file_path("nonexistant-task-id", "file-path")
        expect(last_response.status).to eq(404)
        expect(last_error).to eq("Unknown staging task")
      end
    end

    context "when staging task does exist" do
      before { staging_task_registry.register(staging_task) }

      context "when container path is not available" do
        before { allow(staging_task).to receive(:container_path).and_return(nil) }

        it "returns a 503" do
          get staging_task_file_path(staging_task.task_id, "file-path")
          expect(last_response.status).to eq(503)
          expect(last_error).to eq("Staging task unavailable")
        end
      end

      context "when container path does exist" do
        let(:container_rootfs_path) { File.join(tmpdir, "tmp", "rootfs") }

        before do
          FileUtils.mkdir_p(container_rootfs_path)
          allow(staging_task.container).to receive(:path).and_return(tmpdir)
        end

        context "when requested file does not exist" do
          it "returns 404" do
            get staging_task_file_path(staging_task.task_id, "file-path-that-does-not-exist")
            expect(last_response.status).to eq(404)
            expect(last_error).to eq("Entity not found")
          end
        end

        context "when requested file path points outside the container's directory" do
          it "returns 403" do
            get staging_task_file_path(staging_task.task_id, "..")
            expect(last_response.status).to eq(403)
            expect(last_error).to eq("Not accessible")
          end
        end

        context "when file exists" do
          let(:expanded_file_path) { File.join(container_rootfs_path, "some-file") }
          before { FileUtils.touch(expanded_file_path) }

          it "returns expanded path" do
            get staging_task_file_path(staging_task.task_id, "some-file")
            expect(last_response.status).to eq(200)
            expect(json_body["instance_path"]).to eq(expanded_file_path)
          end
        end
      end
    end
  end

  alias_method :app, :described_class

  def staging_task_file_path(task_id, file_path, options={})
    directory_server.staging_task_file_url_for(task_id, file_path).tap do |url|
      url.gsub!(/hmac=.+([^\&]|$)/, "hmac=#{options[:hmac]}") if options[:hmac]
    end
  end

  def json_body
    JSON.parse(last_response.body)
  end

  def last_error
    expect(json_body).to be_kind_of(Hash)
    json_body["error"]
  end
end
