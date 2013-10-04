require "spec_helper"
require "dea/staging_task_workspace"

describe Dea::StagingTaskWorkspace do

  let(:base_dir) do
    Dir.mktmpdir
  end

  let(:system_buildpack_dir) do
    Pathname.new(File.expand_path("../../../buildpacks/vendor", __FILE__)).children.map(&:to_s)
  end

  let(:admin_buildpacks) do
    [{
       "url" => "http://example.com/buildpacks/uri/abcdef",
       "key" => "abcdef"
     },
     {
       "url" => "http://example.com/buildpacks/uri/ghijk",
       "key" => "ghijk"
     }]
  end

  let(:env_properties) do
    {
      a: 1,
      b: 2,
    }
  end

  let(:buildpacks_in_use) {[]}

  subject do
    Dea::StagingTaskWorkspace.new(base_dir, admin_buildpacks, buildpacks_in_use, env_properties)
  end

  before do
    AdminBuildpackDownloader.stub(:new).and_return(downloader)
  end

  after { FileUtils.rm_f(base_dir) }

  let(:downloader) { double("AdminBuildpackDownloader").as_null_object }

  describe "cleaning up deleted admin buildpacks" do
    let(:admin_buildpacks) do
      [
        {
          "url" => "http://example.com/buildpacks/uri/abcdef",
          "key" => "abcdef"
        }
      ]
    end

    let(:file_to_delete) {File.join(subject.admin_buildpacks_dir, "1234") }
    let(:file_to_keep) {File.join(subject.admin_buildpacks_dir, "abcdef") }

    before do
      [file_to_delete, file_to_keep].each do |path|
        create_populated_directory path
      end
    end

    def create_populated_directory(path)
      FileUtils.mkdir_p(File.join(path, "a_buildpack_file"))
    end

    context "when there are no admin buildpacks in use" do
      let(:builpacks_in_use) {[]}

      it "cleans deleted admin buildpacks" do
        expect { subject.prepare }.to change { File.exists? file_to_delete }.from(true).to(false)
        expect(File.exists? file_to_keep).to be_true
      end
    end

    context "when an admin buildpack is in use" do
      let(:buildpacks_in_use) {["efghi"]}
      let(:file_in_use) {File.join(subject.admin_buildpacks_dir, "efghi")}

      before do
        create_populated_directory(file_in_use)
      end

      it "that buildpack doesn't get deleted" do
        expect { subject.prepare }.to change { File.exists? file_to_delete }.from(true).to(false)
        expect(File.exists? file_to_keep).to be_true
        expect(File.exists? file_in_use).to be_true
      end
    end
  end

  describe "preparing the workspace" do
    it "downloads the admin buildpacks" do
      AdminBuildpackDownloader.should_receive(:new).with(admin_buildpacks, subject.admin_buildpacks_dir).and_return(downloader)
      downloader.should_receive(:download)
      subject.prepare
    end

    describe "the plugin config file" do
      context "when admin buildpack exists" do
        before do
          @admin_buildpack = File.join(subject.admin_buildpacks_dir, "abcdef")
          Dir.mkdir(@admin_buildpack)
          subject.prepare
          @config = YAML.load_file(subject.plugin_config_path)
        end

        after do
          FileUtils.rm_f(@admin_buildpack)
        end

        it "includes the admin buildpacks" do
          expect(@config["buildpack_dirs"]).to include(@admin_buildpack)
        end

        it "admin buildpack should come first" do
          expect(@config["buildpack_dirs"][0]).to eq(@admin_buildpack)
        end
      end

      context "when multiple admin buildpacks exist" do
        before do
          @admin_buildpack = File.join(subject.admin_buildpacks_dir, "abcdef")
          Dir.mkdir(@admin_buildpack)
          @another_buildpack = File.join(subject.admin_buildpacks_dir, "xyz")
          Dir.mkdir(@another_buildpack)
          subject.prepare
          @config = YAML.load_file(subject.plugin_config_path)
        end

        after do
          FileUtils.rm_f(@admin_buildpack)
          FileUtils.rm_f(@another_buildpack)
        end

        it "only returns buildpacks specified in start message" do
          expect(@config["buildpack_dirs"][0]).to eq(@admin_buildpack)
          expect(@config["buildpack_dirs"]).to_not include(@another_buildpack)
        end
      end

      context "when admin buildpack does not exist" do
        before do
          subject.prepare
          @config = YAML.load_file(subject.plugin_config_path)
        end

        it "has the right source, destination and cache directories" do
          expect(@config["source_dir"]).to eq("/tmp/unstaged")
          expect(@config["dest_dir"]).to eq("/tmp/staged")
          expect(@config["cache_dir"]).to eq("/tmp/cache")
        end

        it "includes the specified environment config" do
          expect(@config["environment"]).to eq(env_properties)
        end

        it "includes the staging info path" do
          expect(@config["staging_info_name"]).to eq("staging_info.yml")
        end

        it "include the system buildpacks" do
          expect(@config["buildpack_dirs"]).to eq(system_buildpack_dir)
        end
      end
    end
  end

  it "creates the tmp folder" do
    subject
    expect(File.exists?(subject.tmpdir)).to be_true
  end

  it "creates the admin buildpacks dir folder" do
    subject
    expect(File.exists?(subject.admin_buildpacks_dir)).to be_true
  end
end