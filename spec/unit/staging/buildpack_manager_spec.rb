require 'spec_helper'
require 'dea/staging/buildpack_manager'
require 'dea/staging/staging_message'

describe Dea::BuildpackManager do
  let(:base_dir) { Dir.mktmpdir }
  let(:admin_buildpacks_dir) { "#{base_dir}/admin_buildpacks" }

  let(:admin_buildpacks) { [{url: URI("http://example.com/buildpacks/uri/abcdef"), key: "abcdef"}] }
  let(:buildpacks_in_use) { [] }

  let(:staging_message) do
    attributes = valid_staging_attributes
    attributes['admin_buildpacks'] = admin_buildpacks.map do |bp|
      { "url" => bp[:url].to_s, "key" => bp[:key] }
    end
    StagingMessage.new(attributes)
  end

  after { FileUtils.rm_rf(base_dir) }

  subject(:manager) { Dea::BuildpackManager.new(admin_buildpacks_dir, staging_message, buildpacks_in_use) }

  def create_populated_directory(path)
    FileUtils.mkdir_p(File.join(path, "a_buildpack_file")) if path
  end

  describe "#download" do
    it "calls AdminBuildpackDownloader" do
      downloader_mock = double(:downloader)
      allow(downloader_mock).to receive(:download)
      allow(AdminBuildpackDownloader).to receive(:new).with(admin_buildpacks, admin_buildpacks_dir) { downloader_mock }

      manager.download
    end
  end

  describe "#clean" do
    let(:file_to_delete) { File.join(admin_buildpacks_dir, "1234") }
    let(:file_to_keep) { File.join(admin_buildpacks_dir, "abcdef") }

    before do
      [file_to_delete, file_to_keep].each do |path|
        create_populated_directory path
      end
    end

    context "when there are no admin buildpacks in use" do
      it "cleans deleted admin buildpacks" do
        expect {
          manager.clean
        }.to change {
          File.exists? file_to_delete
        }.from(true).to(false)

        expect(File.exists? file_to_keep).to be true
      end
    end

    context "when an admin buildpack is in use" do
      let(:buildpacks_in_use) { [{uri: URI("http://www.example.com"), key: "efghi"}] }

      let(:file_in_use) {File.join(admin_buildpacks_dir, "efghi")}

      before do
        create_populated_directory(file_in_use)
      end

      it "that buildpack doesn't get deleted" do
        expect {
          manager.clean
        }.to change {
          File.exists? file_to_delete
        }.from(true).to(false)
        expect(File.exists? file_to_keep).to be true
        expect(File.exists? file_in_use).to be true
      end
    end
  end

  describe "#buildpack_dirs" do
    let(:admin_buildpacks) do
      [
        {
          url: "http://example.com/buildpacks/uri/z_admin",
          key: "z_admin"
        },
        {
          url: "http://example.com/buildpacks/uri/admin",
          key: "admin"
        },
        {
          url: "http://example.com/buildpacks/uri/another_admin",
          key: "another_admin"
        }
      ]
    end

    context "when admin buildpacks have been downloaded" do
      before do
        admin_buildpacks.each do |bp|
          create_populated_directory(File.join(admin_buildpacks_dir, bp[:key]))
        end
      end

      it "has an item for every buildpack that's both in the staging message and on disk" do
        expect(manager.buildpack_dirs.size).to eq(3)
      end

      it "returns the buildpacks in the same order as the staging message" do
        expect(manager.buildpack_dirs[0]).to eq(File.join(admin_buildpacks_dir, "z_admin"))
        expect(manager.buildpack_dirs[1]).to eq(File.join(admin_buildpacks_dir, "admin"))
        expect(manager.buildpack_dirs[2]).to eq(File.join(admin_buildpacks_dir, "another_admin"))
      end

      context "when stale admin buildpacks still exist on disk" do
        it "only returns buildpacks specified in staging message" do
          create_populated_directory(File.join(admin_buildpacks_dir, "not_in_staging_message"))
          expect(manager.buildpack_dirs.size).to eq(3)
        end
      end

      context "when a buildpack from the staging message does not exist on disk" do
        before { FileUtils.rm_rf("#{admin_buildpacks_dir}/z_admin") }

        it "copes with an admin buildpack not being there" do
          expect(manager.buildpack_dirs).to include("#{admin_buildpacks_dir}/admin")
          expect(manager.buildpack_dirs).to include("#{admin_buildpacks_dir}/another_admin")
        end

        it "should not include admin buildpacks which are missing" do
          expect(manager.buildpack_dirs).to_not include("#{admin_buildpacks_dir}/z_admin")
        end
      end
    end

    context "when there are no admin buildpacks on disk" do
      it "reports no buildpacks" do
        expect(manager.buildpack_dirs).to be_empty
      end
    end
  end

  describe "buildpack keys" do
    let(:admin_buildpack) { File.join(admin_buildpacks_dir, "admin") }

    before do
      create_populated_directory(admin_buildpack)
    end

    describe "#buildpack_key" do
      it "should be the buildpack key for an admin buildpack" do
        expect(subject.buildpack_key(admin_buildpack)).to eq("admin")
      end

      it "should be nil for a custom buildpack" do
        expect(subject.buildpack_key("/tmp/cloned")).to be_nil
      end

      it "should be nil for a nil buildpack dir" do
        expect(subject.buildpack_key(nil)).to be_nil
      end
    end
  end
end
