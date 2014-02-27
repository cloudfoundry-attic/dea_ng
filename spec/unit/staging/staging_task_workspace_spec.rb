require "spec_helper"
require "dea/staging/staging_task_workspace"
require "dea/staging/staging_message"

describe Dea::StagingTaskWorkspace do
  platform_specific(:platform, default_platform: :Linux)

  let(:base_dir) { Dir.mktmpdir }

  let(:system_buildpack_dir) do
    Pathname.new(File.expand_path("../../../../buildpacks/vendor", __FILE__)).children.sort.map(&:to_s)
  end

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

  let(:env_properties) do
    {
      "a" => 1,
      "b" => 2,
    }
  end

  let(:staging_message) do
    StagingMessage.new(
      "admin_buildpacks" => admin_buildpacks,
      "properties" => env_properties
    )
  end

  let(:buildpacks_in_use) { [] }

  subject do
    Dea::StagingTaskWorkspace.new(base_dir, staging_message, buildpacks_in_use)
  end

  before do
    AdminBuildpackDownloader.stub(:new).and_return(downloader)
  end

  after { FileUtils.rm_f(base_dir) }

  let(:downloader) { double("AdminBuildpackDownloader").as_null_object }

  describe "preparing the workspace" do
    it "downloads the admin buildpacks" do
      AdminBuildpackDownloader.should_receive(:new).with(instance_of(Array), subject.admin_buildpacks_dir).and_return(downloader)
      downloader.should_receive(:download)
      subject.prepare
    end

    describe "the plugin config file" do
      context "when admin buildpack exists" do
        before do
          subject.prepare
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
          subject.prepare
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

      context "when the config lists multiple admin buildpacks which exist on disk" do
        before do
          subject.prepare
          @admin_buildpack = File.join(subject.admin_buildpacks_dir, "abcdef")
          Dir.mkdir(@admin_buildpack)
          @another_buildpack = File.join(subject.admin_buildpacks_dir, "ghijk")
          Dir.mkdir(@another_buildpack)
          subject.prepare
          @config = YAML.load_file(subject.plugin_config_path)
        end

        after do
          FileUtils.rm_f(@admin_buildpack)
          FileUtils.rm_f(@another_buildpack)
        end

        context "when the buildpacks are ordered admin_buildpack, another_buildpack" do
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

          it "returns the buildpacks in the order of the admin_buildpacks message" do
            expect(@config["buildpack_dirs"][0]).to eq(@admin_buildpack)
            expect(@config["buildpack_dirs"][1]).to eq(@another_buildpack)
          end
        end

        context "when the buildpacks are ordered another_buildpack, admin_buildpack" do
          let(:admin_buildpacks) do
            [
              {
                "url" => "http://example.com/buildpacks/uri/ghijk",
                "key" => "ghijk"
              },
              {
                "url" => "http://example.com/buildpacks/uri/abcdef",
                "key" => "abcdef"
              }
            ]
          end

          it "returns the buildpacks in the order of the admin_buildpacks message" do
            expect(@config["buildpack_dirs"][0]).to eq(@another_buildpack)
            expect(@config["buildpack_dirs"][1]).to eq(@admin_buildpack)
          end
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
    subject.prepare
    expect(File.exists?(subject.tmpdir)).to be_true
  end

  it "creates the admin buildpacks dir folder" do
    subject.prepare
    expect(File.exists?(subject.admin_buildpacks_dir)).to be_true
  end
end
