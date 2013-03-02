# coding: UTF-8

require "spec_helper"
require "dea/staging_task"
require "dea/directory_server_v2"
require "em-http"

describe Dea::StagingTask do
  let(:config) do
    {
      "base_dir" => ".",
      "directory_server" => {"file_api_port" => 1234},
      "staging" => {"environment" => {}, "platform_config" => {}},
    }
  end

  let(:bootstrap) { mock(:bootstrap, :config => config) }
  let(:dir_server) { Dea::DirectoryServerV2.new("domain", 1234, config) }

  let(:logger) do
    mock("logger").tap do |l|
      %w(debug debug2 info warn).each { |m| l.stub(m) }
    end
  end

  let(:attributes) { valid_staging_attributes }
  let(:staging) { Dea::StagingTask.new(bootstrap, dir_server, attributes) }
  let(:workspace_dir) { Dir.mktmpdir("somewhere") }

  before do
    staging.stub(:workspace_dir) { workspace_dir }
    staging.stub(:staged_droplet_path) { __FILE__ }
    staging.stub(:downloaded_droplet_path) { "/path/to/downloaded/droplet" }
    staging.stub(:logger) { logger }
  end

  describe "#promise_stage" do
    let(:staging_env) { "PATH=x FOO=y" }
    it "assembles a shell command and initiates collection of task log" do
      staging.should_receive(:staging_environment).and_return(staging_env)

      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        cmd.should match %r{^PATH=x FOO=y .*/bin/run_plugin .*/plugin_config > /tmp/staged/logs/staging_task.log 2>&1$}
        mock("promise", :resolve => nil)
      end

      staging.should_receive(:promise_task_log) { mock("promise", :resolve => nil) }

      staging.promise_stage.resolve
    end

    it "initiates collection of task log if script fails to run" do
      staging.should_receive(:staging_environment).and_return(staging_env)

      staging.should_receive(:promise_warden_run) { raise RuntimeError.new("Script Failed") }

      staging.should_receive(:promise_task_log) { mock("promise", :resolve => nil) }

      expect { staging.promise_stage.resolve }.to raise_error "Script Failed"
    end
  end

  describe "#task_id" do
    subject { Dea::StagingTask.new(bootstrap, dir_server, attributes) }

    it "generates a guid" do
      VCAP.should_receive(:secure_uuid).and_return("the_uuid")
      subject.task_id.should == "the_uuid"
    end

    it "persists" do
      VCAP.should_receive(:secure_uuid).once.and_return("the_uuid")
      subject.task_id.should == "the_uuid"
      subject.task_id.should == "the_uuid"
    end
  end

  describe "#task_log" do
    subject { staging.task_log }

    describe "when staging has not yet started" do
      it { should be_nil }
    end

    describe "once staging has started" do
      before do
        File.open(File.join(workspace_dir, "staging_task.log"), "w") do |f|
          f.write "some log content"
        end
      end

      it "reads the staging log file" do
        staging.task_log.should == "some log content"
      end
    end
  end

  describe "#streaming_log_url" do
    let(:url) { staging.streaming_log_url }

    it "returns url for staging log" do
      url.should include("/staging_tasks/#{staging.task_id}/file_path", )
    end

    it "includes path to staging task output" do
      url.should include "path=%2Ftmp%2Fstaged%2Flogs%2Fstaging_task.log"
    end

    it "hmacs url" do
      url.should match(/hmac=.*/)
    end
  end

  describe "#prepare_workspace" do
    describe "the plugin config file" do
      subject do
        staging.prepare_workspace
        YAML.load_file("#{workspace_dir}/plugin_config")
      end

      it "has the right source and destination directories" do
        expect(subject["source_dir"]).to eq("/tmp/unstaged")
        expect(subject["dest_dir"]).to eq("/tmp/staged")
      end

      it "includes the specified environment config" do
        environment_config = attributes["properties"]
        expect(subject["environment"]).to eq(environment_config)
      end
    end

    describe "the platform config file" do
      subject do
        staging.prepare_workspace
        YAML.load_file("#{workspace_dir}/platform_config")
      end

      it "includes the cache directory path" do
        expect(subject["cache"]).to eq("/tmp/cache")
      end
    end
  end

  describe "#path_in_container" do
    context "when given path is not nil" do
      context "when container path is set" do
        before { staging.stub(:container_path => "/container/path") }

        it "returns path inside warden container root file system" do
          staging.path_in_container("path/to/file").should == "/container/path/tmp/rootfs/path/to/file"
        end
      end

      context "when container path is not set" do
        before { staging.stub(:container_path => nil) }

        it "returns nil" do
          staging.path_in_container("path/to/file").should be_nil
        end
      end
    end

    context "when given path is nil" do
      context "when container path is set" do
        before { staging.stub(:container_path => "/container/path") }

        it "returns path inside warden container root file system" do
          staging.path_in_container(nil).should == "/container/path/tmp/rootfs/"
        end
      end

      context "when container path is not set" do
        before { staging.stub(:container_path => nil) }

        it "returns nil" do
          staging.path_in_container("path/to/file").should be_nil
        end
      end
    end
  end

  describe "#start" do
    let(:successful_promise) { Dea::Promise.new {|p| p.deliver } }
    let(:failing_promise) { Dea::Promise.new {|p| raise "failing promise" } }

    def stub_staging_setup
      staging.stub(:prepare_workspace)
      staging.stub(:promise_app_download).and_return(successful_promise)
      staging.stub(:promise_create_container).and_return(successful_promise)
      staging.stub(:promise_prepare_staging_log).and_return(successful_promise)
      staging.stub(:promise_container_info).and_return(successful_promise)
      staging.stub(:promise_app_dir).and_return(successful_promise)
    end

    def stub_staging
      staging.stub(:promise_unpack_app).and_return(successful_promise)
      staging.stub(:promise_stage).and_return(successful_promise)
      staging.stub(:promise_pack_app).and_return(successful_promise)
      staging.stub(:promise_copy_out).and_return(successful_promise)
      staging.stub(:promise_app_upload).and_return(successful_promise)
      staging.stub(:promise_destroy).and_return(successful_promise)
    end

    def self.it_calls_callback(callback_name, options={})
      describe "after_#{callback_name}_callback" do
        before do
          stub_staging_setup
          stub_staging
        end

        context "when there is no callback registered" do
          it "doesn't not try to call registered callback" do
            staging.start
          end
        end

        context "when there is callback registered" do
          before do
            @received_count = 0
            @received_error = nil
            staging.send("after_#{callback_name}_callback") do |error|
              @received_count += 1
              @received_error = error
            end
          end

          context "and staging task succeeds finishing #{callback_name}" do
            it "calls registered callback without an error" do
              staging.start
              @received_count.should == 1
              @received_error.should be_nil
            end
          end

          context "and staging task fails before finishing #{callback_name}" do
            before { staging.stub(options[:failure_cause]).and_return(failing_promise) }

            it "calls registered callback with an error" do
              staging.start rescue nil
              @received_count.should == 1
              @received_error.to_s.should == "failing promise"
            end
          end

          context "and the callback itself fails" do
            before do
              staging.send("after_#{callback_name}_callback") do |_|
                @received_count += 1
                raise "failing callback"
              end
            end

            it "cleans up workspace" do
              staging.should_receive(:clean_workspace)
              staging.start rescue nil
            end if options[:callback_failure_cleanup_assertions]

            it "calls registered callback exactly once" do
              staging.start rescue nil
              @received_count.should == 1
            end

            context "and there is no error from staging" do
              it "raises error raised in the callback" do
                expect {
                  staging.start
                }.to raise_error(/failing callback/)
              end
            end

            context "and there is an error from staging" do
              before { staging.stub(options[:failure_cause]).and_return(failing_promise) }

              it "raises the staging error" do
                expect {
                  staging.start
                }.to raise_error(/failing callback/)
              end
            end
          end
        end
      end
    end

    it_calls_callback :setup, :failure_cause => :promise_app_download

    it_calls_callback :complete, {
      :failure_cause => :promise_destroy,
      :callback_failure_cleanup_assertions => true
    }

    it "should clean up after itself" do
      staging.stub(:prepare_workspace).and_raise("Error")
      expect { staging.start }.to raise_error(/Error/)
      File.exists?(workspace_dir).should be_false
    end

    it "prepare workspace, download app source, creates container, prepares staging log, creates app dir and then obtains container info" do
      %w(prepare_workspace
         promise_app_download
         promise_create_container
         promise_prepare_staging_log
         promise_app_dir
         promise_container_info
      ).each do |step|
        staging.should_receive(step).ordered.and_return(successful_promise)
      end

      stub_staging
      staging.start
    end

    it "unpacks, stages, repacks, copies files out of container, upload staged app and then destroys" do
      %w(unpack_app stage pack_app copy_out app_upload destroy).each do |step|
        staging.should_receive("promise_#{step}").ordered.and_return(successful_promise)
      end

      stub_staging_setup
      staging.start
    end
  end

  describe "#promise_prepare_staging_log" do
    it "assembles a shell command that creates staging_task.log file for tailing it" do
      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        cmd.should match "mkdir -p /tmp/staged/logs && touch /tmp/staged/logs/staging_task.log"
        mock(:prepare_staging_log_promise, :resolve => nil)
      end
      staging.promise_prepare_staging_log.resolve
    end
  end

  describe "#promise_container_info" do
    def resolve_promise
      staging.promise_container_info.resolve
    end

    context "when container handle is set" do
      let(:warden_info_response) do
        Warden::Protocol::InfoResponse.new(:container_path => "/container/path")
      end

      before { staging.stub(:container_handle => "container-handle") }

      it "makes warden info request" do
        staging.should_receive(:promise_warden_call).and_return do |type, request|
          type.should == :info
          request.handle.should == "container-handle"
          mock(:promise, :resolve => warden_info_response)
        end

        resolve_promise
      end

      context "when container_path is provided" do
        it "sets container_path" do
          staging.stub(:promise_warden_call).and_return do
            mock(:promise, :resolve => warden_info_response)
          end

          expect {
            resolve_promise
          }.to change { staging.container_path }.from(nil).to("/container/path")
        end
      end

      context "when container_path is not provided" do
        it "raises error" do
          staging.stub(:promise_warden_call).and_return do
            response = Warden::Protocol::InfoResponse.new
            mock(:promise, :resolve => response)
          end

          expect {
            resolve_promise
          }.to raise_error(RuntimeError, /container path is not available/)
        end
      end
    end

    context "when container handle is not set" do
      before { staging.stub(:container_handle => nil) }

      it "raises error" do
        expect {
          resolve_promise
        }.to raise_error(ArgumentError, /container handle must not be nil/)
      end
    end
  end

  describe "#promise_app_download" do
    subject do
      promise = staging.promise_app_download
      promise.resolve
      promise
    end

    context "when there is an error" do
      before { Download.any_instance.stub(:download!).and_yield("This is an error", nil) }
      it { expect { subject }.to raise_error(RuntimeError, "This is an error") }
    end

    context "when there is no error" do
      before do
        File.stub(:rename)
        File.stub(:chmod)
        Download.any_instance.stub(:download!).and_yield(nil, "/path/to/file")
      end
      its(:result) { should == [:deliver, nil]}

      it "should rename the file" do
        File.should_receive(:rename).with("/path/to/file", "/path/to/downloaded/droplet")
        File.should_receive(:chmod).with(0744, "/path/to/downloaded/droplet")
        subject
      end
    end
  end

  describe "#promise_unpack_app" do
    it "assembles a shell command" do
      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        cmd.should include("unzip -q /path/to/downloaded/droplet -d /tmp/unstaged")
        mock("promise", :resolve => nil)
      end

      staging.promise_unpack_app.resolve
    end
  end

  describe "#promise_pack_app" do
    it "assembles a shell command" do
      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        cmd.should include("cd /tmp/staged && COPYFILE_DISABLE=true tar -czf /tmp/droplet.tgz .")
        mock("promise", :resolve => nil)
      end

      staging.promise_pack_app.resolve
    end
  end

  describe "#promise_app_upload" do
    subject do
      promise = staging.promise_app_upload
      promise.resolve
      promise
    end

    context "when there is an error" do
      before { Upload.any_instance.stub(:upload!).and_yield("This is an error") }
      it { expect { subject }.to raise_error(RuntimeError, "This is an error") }
    end

    context "when there is no error" do
      before { Upload.any_instance.stub(:upload!).and_yield(nil) }
      its(:result) { should == [:deliver, nil]}
    end
  end

  describe "#promise_copy_out" do
    subject do
      promise = staging.promise_copy_out
      promise.resolve
      promise
    end

    it "should print out some info" do
      staging.stub(:copy_out_request)
      logger.should_receive(:info).with(anything)
      subject
    end

    it "should send copying out request" do
      staging.should_receive(:copy_out_request).with(Dea::StagingTask::WARDEN_STAGED_DROPLET, /.{5,}/)
      subject
    end
  end

  describe "#promise_task_log" do
    subject do
      promise = staging.promise_task_log
      promise.resolve
      promise
    end

    it "should send copying out request" do
      staging.should_receive(:copy_out_request).with(Dea::StagingTask::WARDEN_STAGING_LOG, /#{workspace_dir}/)
      subject
    end

    it "should write the staging log to the main logger" do
      logger.should_receive(:info).with(anything)
      staging.should_receive(:copy_out_request).with(Dea::StagingTask::WARDEN_STAGING_LOG, /#{workspace_dir}/)
      subject
    end
  end
end
