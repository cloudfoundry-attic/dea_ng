# coding: UTF-8

require "spec_helper"
require "dea/staging_task"
require "em-http"

describe Dea::StagingTask do
  let(:bootstrap) do
    mock = mock("bootstrap")
    mock.stub(:config) { {"base_dir" => ".", "staging" => {"environment" => {}}} }
    mock
  end
  let(:logger) do
    mock = mock("logger")
    mock.stub(:debug)
    mock.stub(:debug2)
    mock.stub(:info)
    mock.stub(:warn)
    mock
  end
  let(:staging) { Dea::StagingTask.new(bootstrap, valid_staging_attributes) }
  let(:workspace_dir) { Dir.mktmpdir("somewhere") }

  before do
    staging.stub(:workspace_dir) { workspace_dir }
    staging.stub(:staged_droplet_path) { __FILE__ }
    staging.stub(:downloaded_droplet_path) { "/path/to/downloaded/droplet" }
    staging.stub(:logger) { logger }
  end

  describe "#promise_stage" do
    let(:staging_env) { { "PATH" => "x", "FOO" => "y" } }
    it "assembles a shell command and initiates collection of task log" do
      staging.should_receive(:staging_environment).and_return(staging_env)

      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        staging_env.each do |k, v|
          cmd.should include("#{k}=#{v}")
        end

        cmd.should include("mkdir /tmp/staged")
        cmd.should include("bin/run_plugin")
        cmd.should include("plugin_config")
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
    it "generates a guid" do
      VCAP.should_receive(:secure_uuid).and_return("the_uuid")
      staging.task_id.should == "the_uuid"
    end

    it "persists" do
      VCAP.should_receive(:secure_uuid).once.and_return("the_uuid")
      staging.task_id.should == "the_uuid"
      staging.task_id.should == "the_uuid"
    end
  end

  describe "#task_log" do
    subject { staging.task_log }

    describe "when staging has not yet started" do
      it { should be_nil }
    end

    describe "once staging has started" do
      before do
        File.open(File.join(workspace_dir, "staging.log"), "w") do |f|
          f.write "some log content"
        end
      end

      it "reads the staging log file" do
        staging.task_log.should == "some log content"
      end
    end
  end

  describe "#start" do
    it "should clean up after itself" do
      staging.stub(:prepare_workspace).and_raise("Error")

      expect { staging.start }.to raise_error(/Error/)

      File.exists?(workspace_dir).should be_false
    end
  end

  describe "#finish_task" do
    context "when an error is passed" do
      let(:fake_error) { StandardError.new("fake error") }

      it "calls the callback with the error, then raises the error" do
        expect {
          staging.finish_task(fake_error) do |error|
            error.should == fake_error
          end
        }.to raise_error(fake_error)
      end
    end

    context "when no error is passed" do
      it "cleans up the workspace after calling the callback" do
        callback_called = false

        staging.finish_task(nil) do
          callback_called = true
          File.exists?(workspace_dir).should be_true
        end

        callback_called.should be_true
        File.exists?(workspace_dir).should be_false
      end
    end
  end

  describe '#promise_app_download' do
    subject do
      promise = staging.promise_app_download
      promise.resolve
      promise
    end

    context 'when there is an error' do
      before { Download.any_instance.stub(:download!).and_yield("This is an error", nil) }
      it { expect { subject }.to raise_error(RuntimeError, "This is an error") }
    end

    context 'when there is no error' do
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

  describe '#promise_app_upload' do
    subject do
      promise = staging.promise_app_upload
      promise.resolve
      promise
    end

    context 'when there is an error' do
      before { Upload.any_instance.stub(:upload!).and_yield("This is an error") }
      it { expect { subject }.to raise_error(RuntimeError, "This is an error") }
    end

    context 'when there is no error' do
      before { Upload.any_instance.stub(:upload!).and_yield(nil) }
      its(:result) { should == [:deliver, nil]}
    end
  end

  describe '#promise_copy_out' do
    subject do
      promise = staging.promise_copy_out
      promise.resolve
      promise
    end

    it 'should print out some info' do
      staging.stub(:copy_out_request)
      logger.should_receive(:info).with(anything)
      subject
    end

    it 'should send copying out request' do
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

    it 'should send copying out request' do
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
