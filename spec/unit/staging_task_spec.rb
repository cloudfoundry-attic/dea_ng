# coding: UTF-8

require "spec_helper"
require "dea/staging_task"
require "dea/directory_server_v2"
require "dea/config"
require "em-http"

describe Dea::StagingTask do
  let(:memory_limit_mb) { 256 }
  let(:disk_limit_mb) { 1025 }

  let!(:workspace_dir) do
    staging.workspace.workspace_dir # force workspace creation
  end

  let(:max_staging_duration) { 900 }

  let(:config) do
    {
      "base_dir" => Dir.mktmpdir("base_dir"),
      "directory_server" => {
        "file_api_port" => 1234
      },
      "staging" => {
        "environment" => {},
        "platform_config" => {},
        "memory_limit_mb" => memory_limit_mb,
        "disk_limit_mb" => disk_limit_mb,
        "max_staging_duration" => max_staging_duration
      },
    }
  end

  let(:bootstrap) { mock(:bootstrap, :config => Dea::Config.new(config)) }
  let(:dir_server) { Dea::DirectoryServerV2.new("domain", 1234, config) }

  let(:logger) do
    mock("logger").tap do |l|
      %w(debug debug2 info warn log_exception error).each { |m| l.stub(m) }
    end
  end

  let(:attributes) { valid_staging_attributes }
  let(:staging) { Dea::StagingTask.new(bootstrap, dir_server, attributes) }

  let(:successful_promise) { Dea::Promise.new {|p| p.deliver } }
  let(:failing_promise) { Dea::Promise.new {|p| raise "failing promise" } }

  before do
    staging.stub(:workspace_dir) { workspace_dir }
    staging.stub(:staged_droplet_path) { __FILE__ }
    staging.stub(:downloaded_droplet_path) { "/path/to/downloaded/droplet" }
    staging.stub(:logger) { logger }
    staging.stub(:container_exists?) { true }
  end

  describe "#promise_stage" do
    let(:staging_env) { "PATH=x FOO=y" }
    it "assembles a shell command and initiates collection of task log" do
      staging.should_receive(:staging_environment).and_return(staging_env)
      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        cmd.should match %r{^PATH=x FOO=y .*/bin/run .*/plugin_config >> /tmp/staged/logs/staging_task.log 2>&1$}
        mock("promise", :resolve => nil)
      end

      staging.promise_stage.resolve
    end

    describe "timeouts" do
      let(:max_staging_duration) { 0.5 }

      context "when the staging times out past the grace period" do
        it "fails with a TimeoutError" do
          staging.stub(:staging_timeout_grace_period) { 0.5 }

          staging.should_receive(:promise_warden_run) do
            promise = mock("promise")
            promise.should_receive(:resolve) { sleep 2 }
            promise
          end

          expect { staging.promise_stage.resolve }.to raise_error(TimeoutError)
        end
      end

      context "when the staging finishes within the grace period" do
        it "does not time out" do
          staging.stub(:staging_timeout_grace_period) { 0.5 }

          staging.should_receive(:promise_warden_run) do
            promise = mock("promise")
            promise.should_receive(:resolve) { sleep 0.75 }
            promise
          end

          expect { staging.promise_stage.resolve }.to_not raise_error
        end
      end
    end
  end

  describe "#task_log" do
    describe "when staging has not yet started" do
      subject { staging.task_log }
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

  describe "#task_info" do
    context "when staging info file exists" do
      before do
        contents = <<YAML
---
detected_buildpack: Ruby/Rack
YAML
        staging_info = File.join(workspace_dir, "staging_info.yml")
        File.open(staging_info, 'w') {|f| f.write(contents) }
      end

      it "parses staging info file" do
        staging.task_info["detected_buildpack"].should eq("Ruby/Rack")
      end
    end

    context "when staging info file does not exist" do
      it "returns empty hash if" do
        staging.task_info.should be_empty
      end
    end
  end

  describe "#detected_buildpack" do
    before do
      contents = <<YAML
---
detected_buildpack: Ruby/Rack
YAML
      staging_info = File.join(workspace_dir, "staging_info.yml")
      File.open(staging_info, 'w') {|f| f.write(contents) }
    end

    it "returns the detected buildpack" do
      staging.detected_buildpack.should eq("Ruby/Rack")
    end
  end

  describe "#streaming_log_url" do
    let(:url) { staging.streaming_log_url }

    it "returns url for staging log" do
      url.should include("/staging_tasks/#{staging.task_id}/file_path",)
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

      it "has the right source, destination and cache directories" do
        expect(subject["source_dir"]).to eq("/tmp/unstaged")
        expect(subject["dest_dir"]).to eq("/tmp/staged")
        expect(subject["cache_dir"]).to eq("/tmp/cache")
      end

      it "includes the specified environment config" do
        environment_config = attributes["properties"]
        expect(subject["environment"]).to eq(environment_config)
      end

      it "includes the staging info path" do
        expect(subject["staging_info_path"]).to eq("/tmp/staging_info.yml")
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
    def stub_staging_setup
      staging.stub(:prepare_workspace)
      %w(
         app_download
         buildpack_cache_download
         create_container
         limit_disk
         limit_memory
         prepare_staging_log
         app_dir
         container_info
      ).each do |step|
        staging.stub("promise_#{step}").and_return(successful_promise)
      end
    end

    def stub_staging
      %w(unpack_app
         unpack_buildpack_cache
         stage
         pack_app
         copy_out
         log_upload_started
         app_upload
         pack_buildpack_cache
         copy_out_buildpack_cache
         buildpack_cache_upload
         log_upload_finished
         staging_info
         task_log
         destroy
      ).each do |step|
        staging.stub("promise_#{step}").and_return(successful_promise)
      end
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
              expect {
                staging.start rescue nil
              }.to change { File.exists?(workspace_dir) }.from(true).to(false)
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

    context "when a script fails" do
      before do
        stub_staging_setup
        stub_staging
        staging.stub(:promise_stage).and_raise("Script Failed")
      end

      it "still copies out the task log" do
        staging.should_receive(:promise_task_log) { mock("promise", :resolve => nil) }
        staging.start rescue nil
      end

      it "propagates the error" do
        expect { staging.start }.to raise_error(/Script Failed/)
      end
    end

    it "performs staging setup operations in correct order" do
      %w(prepare_workspace
         promise_app_download
         promise_create_container
         promise_limit_disk
         promise_limit_memory
         promise_prepare_staging_log
         promise_app_dir
         promise_container_info
      ).each do |step|
        staging.should_receive(step).ordered.and_return(successful_promise)
      end

      stub_staging
      staging.start
    end

    context "when buildpack_cache_download_uri is provided" do
      before do
        staging.stub(:attributes).and_return(
          valid_staging_attributes.merge({ "buildpack_cache_download_uri" => "http://some_url"}))
      end

      it "downloads buildpack cache" do
        staging.should_receive(:promise_buildpack_cache_download)

        stub_staging
        stub_staging_setup

        staging.start
      end
    end

    it "performs staging operations in correct order" do
      %w(unpack_app
         unpack_buildpack_cache
         stage
         pack_app
         copy_out
         log_upload_started
         app_upload
         save_buildpack_cache
         log_upload_finished
         staging_info
         task_log
         destroy).each do |step|
        staging.should_receive("promise_#{step}").ordered.and_return(successful_promise)
      end

      stub_staging_setup
      staging.start
    end
  end

  describe "#stop" do
    context "if container exists" do
      before { staging.stub(:container_handle) { "maria" } }
      it "sends stop request to warden container" do
        staging.should_receive(:promise_stop).and_return(successful_promise)
        staging.stop
      end
    end

    context "if container does not exist" do
      before { staging.stub(:container_handle) { nil } }
      it "does NOT send stop request to warden container" do
        staging.should_not_receive(:promise_stop)
        staging.stop
      end
    end

    it "calls the callback" do
      callback = lambda {}
      callback.should_receive(:call)
      staging.stop(&callback)
    end

    it "triggers after stop callback" do
      staging.should_receive(:trigger_after_stop)
      staging.stop
    end

    it "unregisters after complete callback" do
      staging.stub(:resolve_staging_setup)
      # Emulate staging stop while running staging
      staging.stub(:resolve_staging) { staging.stop }

      staging.should_not_receive(:after_complete_callback)
      staging.start
    end
  end

  describe "#memory_limit_in_bytes" do
    it "exports memory in bytes as specified in the config file" do
      staging.memory_limit_in_bytes.should eq(1024 * 1024 * memory_limit_mb)
    end

    context "when unspecified" do
      before do
        config["staging"].delete("memory_limit_mb")
      end

      it "uses 1GB as a default" do
        staging.memory_limit_in_bytes.should eq(1024*1024*1024)
      end
    end
  end

  describe "#disk_limit_in_bytes" do
    it "exports disk in bytes as specified in the config file" do
      staging.disk_limit_in_bytes.should eq(1024 * 1024 * disk_limit_mb)
    end

    context "when unspecified" do
      before do
        config["staging"].delete("disk_limit_mb")
      end
      
      it "uses 2GB as a default" do
        staging.disk_limit_in_bytes.should eq(2*1024*1024*1024)
      end
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
      its(:result) { should == [:deliver, nil] }

      it "should rename the file" do
        File.should_receive(:rename).with("/path/to/file", "#{workspace_dir}/app.zip")
        File.should_receive(:chmod).with(0744, "#{workspace_dir}/app.zip")
        subject
      end
    end
  end

  describe "#promise_buildpack_cache_download" do
    subject do
      promise = staging.promise_buildpack_cache_download
      promise.resolve
      promise
    end

    let(:error) { Download::DownloadError.new("This is an error") }

    context "when there is an error" do
      before { Download.any_instance.stub(:download!).and_yield(error, nil) }
      its(:result) { should == [:deliver, nil] }
    end

    context "when there is no error" do
      before do
        File.stub(:rename)
        File.stub(:chmod)
        Download.any_instance.stub(:download!).and_yield(nil, "/path/to/file")
      end
      its(:result) { should == [:deliver, nil] }

      it "should rename the file" do
        File.should_receive(:rename).with("/path/to/file", "#{workspace_dir}/buildpack_cache.tgz")
        File.should_receive(:chmod).with(0744, "#{workspace_dir}/buildpack_cache.tgz")
        subject
      end
    end
  end

  describe "#promise_unpack_app" do
    it "assembles a shell command" do
      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        cmd.should include("unzip -q #{workspace_dir}/app.zip -d /tmp/unstaged")
        mock("promise", :resolve => nil)
      end

      staging.promise_unpack_app.resolve
    end
  end

  describe "#promise_unpack_buildpack_cache" do
    context "when buildpack cache does not exist" do
      it "does not run a warden command" do
        staging.should_not_receive(:promise_warden_run)
        staging.promise_unpack_buildpack_cache.resolve
      end
    end

    context "when buildpack cache exists" do
      before do
        FileUtils.touch("#{workspace_dir}/buildpack_cache.tgz")
      end

      it "assembles a shell command" do
        staging.should_receive(:promise_warden_run) do |_, cmd|
          cmd.should include("tar xfz #{workspace_dir}/buildpack_cache.tgz -C /tmp/cache")
          mock("promise", :resolve => nil)
        end

        staging.promise_unpack_buildpack_cache.resolve
      end
    end
  end

  describe "#promise_pack_app" do
    it "assembles a shell command" do
      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        normalize_whitespace(cmd).should include("cd /tmp/staged && COPYFILE_DISABLE=true tar -czf /tmp/droplet.tgz .")
        mock("promise", :resolve => nil)
      end

      staging.promise_pack_app.resolve
    end
  end

  describe "#promise_pack_buildpack_cache" do
    it "assembles a shell command" do
      staging.should_receive(:promise_warden_run) do |_, cmd|
        normalize_whitespace(cmd).should include("cd /tmp/cache && COPYFILE_DISABLE=true tar -czf /tmp/buildpack_cache.tgz .")
        mock("promise", :resolve => nil)
      end

      staging.promise_pack_buildpack_cache.resolve
    end
  end

  describe "#promise_save_buildpack_cache" do

    context "when packing succeeds" do

      before do
        staging.stub(:promise_pack_buildpack_cache).and_return(successful_promise)
        staging.stub(:promise_copy_out_buildpack_cache).and_return(successful_promise)
        staging.stub(:promise_buildpack_cache_upload).and_return(successful_promise)
      end

      it "copies out the buildpack cache" do
        staging.should_receive(:promise_copy_out_buildpack_cache).and_return(successful_promise)
        staging.promise_save_buildpack_cache.resolve
      end

      it "uploads the buildpack cache" do
        staging.should_receive(:promise_buildpack_cache_upload).and_return(successful_promise)
        staging.promise_save_buildpack_cache.resolve
      end
    end

    context "when packing fails" do

      before { staging.stub(:promise_pack_buildpack_cache).and_return(failing_promise) }

      it "does not copy out the buildpack cache" do
        staging.should_not_receive :promise_copy_out_buildpack_cache
        staging.promise_save_buildpack_cache.resolve
      end

      it "does not upload the buildpack cache" do
        staging.should_not_receive :promise_buildpack_cache_upload
        staging.promise_save_buildpack_cache.resolve
      end

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
      its(:result) { should == [:deliver, nil] }
    end
  end

  describe "#promise_buildpack_cache_upload" do
    subject do
      promise = staging.promise_buildpack_cache_upload
      promise.resolve
      promise
    end

    context "when there is an error" do
      before { Upload.any_instance.stub(:upload!).and_yield("This is an error") }
      it { expect { subject }.to raise_error(RuntimeError, "This is an error") }
    end

    context "when there is no error" do
      before { Upload.any_instance.stub(:upload!).and_yield(nil) }
      its(:result) { should == [:deliver, nil] }
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
      logger.should_receive(:info)
      subject
    end

    it "should send copying out request" do
      staging.should_receive(:copy_out_request).with("/tmp/droplet.tgz", /.{5,}/)
      subject
    end
  end

  describe "#promise_copy_out_buildpack_cache" do
    subject do
      promise = staging.promise_copy_out_buildpack_cache
      promise.resolve
      promise
    end

    it "should send copying out request" do
      staging.should_receive(:copy_out_request).with("/tmp/buildpack_cache.tgz", /.{5,}/)
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
      staging.should_receive(:copy_out_request).with("/tmp/staged/logs/staging_task.log", /#{workspace_dir}/)
      subject
    end

    it "should write the staging log to the main logger" do
      logger.should_receive(:info)
      staging.should_receive(:copy_out_request).with("/tmp/staged/logs/staging_task.log", /#{workspace_dir}/)
      subject
    end
  end

  describe "#promise_staging_info" do
    subject do
      promise = staging.promise_staging_info
      promise.resolve
      promise
    end

    it "should send copying out request" do
      staging.should_receive(:copy_out_request).with("/tmp/staging_info.yml", /#{workspace_dir}/)
      subject
    end
  end

  def normalize_whitespace(script)
    script.gsub(/\s+/, " ")
  end
end
