require "spec_helper"
require "dea/staging/staging_task_workspace"
require "dea/staging/staging_message"

describe Dea::StagingTaskWorkspace do

  let(:base_dir) { Dir.mktmpdir }
  let(:buildpacks_in_use) { [] }

  let(:admin_buildpacks) do
    [
      {
        "url" => "http://example.com/buildpacks/uri/abcdef",
        "key" => "abcdef"
      },
      {
        "url" => "http://example.com/buildpacks/uri/ghijk",
        "key" => "ghijk"
      }
    ]
  end

  let(:buildpack_dirs) do
    [ "/tmp/admin/admin" ]
  end

  let(:buildpack_manager) do
    buildpack_manager = instance_double("Dea::BuildpackManager")
    buildpack_manager.stub(:buildpack_dirs => buildpack_dirs)
    buildpack_manager.stub(:clean)
    buildpack_manager.stub(:download)
    buildpack_manager
  end

  let(:env_properties) do
    {
      "a" => 1,
      "b" => 2,
    }
  end

  subject do
    Dea::StagingTaskWorkspace.new(base_dir, env_properties)
  end

  after { FileUtils.rm_f(base_dir) }

  describe "#workspace_dir" do
    let(:staging_dir) { Pathname.new(base_dir).join("staging") }

    it "should create the staging directory" do
      expect(staging_dir.exist?).to be_false
      subject.workspace_dir
      expect(staging_dir.exist?).to be_true
      expect(staging_dir.directory?).to be_true
    end

    it "should create the workspace directory under the staging directory with the expected permissions" do
      workspace_path = Pathname.new(subject.workspace_dir)
      expect(workspace_path.exist?).to be_true
      expect(workspace_path.directory?).to be_true
      expect(workspace_path.parent).to eq(staging_dir)
      expect(workspace_path.stat.mode.to_s(8)).to end_with("0755")
    end

    it "should return the same workspace directory when called multiple times" do
      expect(subject.workspace_dir).to eq(subject.workspace_dir)
    end
  end

  describe "#prepare" do
    it "creates the tmp folder" do
      subject.prepare(buildpack_manager)
      expect(File.exists?(subject.tmpdir)).to be_true
    end

    it "downloads the admin buildpacks" do
      buildpack_manager.should_receive(:download)
      subject.prepare(buildpack_manager)
    end

    it "deletes stale admin buildpacks" do
      buildpack_manager.should_receive(:clean)
      subject.prepare(buildpack_manager)
    end

    it "creates the plugin config file" do
      subject.prepare(buildpack_manager)
      expect(File.exists?(subject.plugin_config_path)).to be_true
    end
  end

  describe "the plugin config file" do
    before do
      subject.prepare(buildpack_manager)
      @config = YAML.load_file(subject.plugin_config_path)
    end

    it "should contain buildpack data from the buildpack manager" do
      expect(@config["buildpack_dirs"]).to_not be_nil
      expect(@config["buildpack_dirs"]).to eq(buildpack_dirs)
    end

    it "includes the specified environment config" do
      expect(@config["environment"]).to_not be_nil
      expect(@config["environment"]).to eq(env_properties)
    end

    it "includes the staging info path" do
      expect(@config["staging_info_path"]).to_not be_nil
      expect(@config["staging_info_path"]).to eq("/tmp/staged/staging_info.yml")
    end
  end
end
