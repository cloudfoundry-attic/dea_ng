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
    it "assembles a shell command" do
      staging.should_receive(:promise_warden_run) do |connection_name, cmd|
        cmd.should include("mkdir /tmp/staged")
        cmd.should include("bin/run_plugin")
        cmd.should include("plugin_config")
        mock("promise", :resolve => nil)
      end

      staging.promise_stage.resolve
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

  describe "#start" do
    it "should clean up after itself" do
      staging.stub(:prepare_workspace).and_raise("Error")

      expect { staging.start }.to raise_error(/Error/)

      File.exists?(workspace_dir).should be_false
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
end
