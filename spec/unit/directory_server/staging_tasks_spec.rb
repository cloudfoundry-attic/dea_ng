# coding: UTF-8

require "spec_helper"
require "json"
require "rack/test"
require "dea/staging_task"
require "dea/staging_task_registry"
require "dea/directory_server_v2"

describe Dea::DirectoryServerV2::StagingTasks do
  include Rack::Test::Methods
  include_context "tmpdir"

  let(:bootstrap) { mock(:bootstrap, :config => {}) }
  let(:directory_server) { Dea::DirectoryServerV2.new("example.org", 1234, {}) }

  let(:staging_task_registry) { Dea::StagingTaskRegistry.new }
  let(:staging_task) { Dea::StagingTask.new(bootstrap, directory_server, valid_staging_attributes) }

  before { Dea::DirectoryServerV2::StagingTasks.configure(directory_server, staging_task_registry, 1) }

  describe "GET /staging_tasks/<task_id>/file_path" do
    context "when hmac is missing" do
      it "returns a 401" do
        get staging_task_file_path(staging_task.task_id, "file-path", :hmac => "")
        last_response.status.should == 401
        last_error.should == "Invalid HMAC"
      end
    end

    context "when hmac is invalid" do
      it "returns a 401" do
        get staging_task_file_path(staging_task.task_id, "file-path", :hmac => "some-other-hmac")
        last_response.status.should == 401
        last_error.should == "Invalid HMAC"
      end
    end

    context "when url has expired" do
      it "returns a 400" do
        Time.stub(:now => Time.at(10))
        url = staging_task_file_path(staging_task.task_id, "file-path")

        Time.stub(:now => Time.at(12))
        get url

        last_response.status.should == 400
        last_error.should == "Url expired"
      end
    end

    context "when staging task does not exist" do
      it "returns a 404" do
        get staging_task_file_path("nonexistant-task-id", "file-path")
        last_response.status.should == 404
        last_error.should == "Unknown staging task"
      end
    end

    context "when staging task does exist" do
      before { staging_task_registry.register(staging_task) }

      context "when container path is not available" do
        before { staging_task.stub(:container_path => nil) }

        it "returns a 503" do
          get staging_task_file_path(staging_task.task_id, "file-path")
          last_response.status.should == 503
          last_error.should == "Staging task unavailable"
        end
      end

      context "when container path does exist" do
        let(:container_rootfs_path) { File.join(tmpdir, "tmp", "rootfs") }

        before do
          FileUtils.mkdir_p(container_rootfs_path)
          staging_task.stub(:container_path => tmpdir)
        end

        context "when requested file does not exist" do
          it "returns 404" do
            get staging_task_file_path(staging_task.task_id, "file-path-that-does-not-exist")
            last_response.status.should == 404
            last_error.should == "Entity not found"
          end
        end

        context "when requested file path points outside the container's directory" do
          it "returns 403" do
            get staging_task_file_path(staging_task.task_id, "..")
            last_response.status.should == 403
            last_error.should == "Not accessible"
          end
        end

        context "when file exists" do
          let(:expanded_file_path) { File.join(container_rootfs_path, "some-file") }
          before { FileUtils.touch(expanded_file_path) }

          it "returns expanded path" do
            get staging_task_file_path(staging_task.task_id, "some-file")
            last_response.status.should == 200
            json_body["instance_path"].should == expanded_file_path
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
    json_body.should be_kind_of(Hash)
    json_body["error"]
  end
end
