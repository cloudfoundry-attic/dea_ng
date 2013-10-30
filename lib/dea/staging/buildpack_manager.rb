require "dea/staging/admin_buildpack_downloader"

module Dea
  class BuildpackManager
    def initialize (admin_buildpacks_dir, system_buildpacks_dir, admin_buildpacks, buildpacks_in_use)
      @admin_buildpacks_dir = admin_buildpacks_dir
      @system_buildpacks_dir = system_buildpacks_dir
      @admin_buildpacks = admin_buildpacks
      @buildpacks_in_use = buildpacks_in_use
    end

    def download
      AdminBuildpackDownloader.new(@admin_buildpacks, @admin_buildpacks_dir).download
    end

    def clean
      buildpacks_needing_deletion.each do |path|
        FileUtils.rm_rf(path)
      end
    end

    def list
      admin_buildpacks_in_staging_message + system_buildpack_paths
    end

    private

    def buildpacks_needing_deletion
      all_buildpack_paths - (admin_buildpacks_in_staging_message + buildpacks_in_use_paths)
    end

    def admin_buildpacks_in_staging_message
      @admin_buildpacks.map do |buildpack|
        Pathname.new(File.join(@admin_buildpacks_dir, buildpack[:key]))
      end.select{ |path| File.exists? path }.map(&:to_s)
    end

    def buildpacks_in_use_paths
      @buildpacks_in_use.map { |b| File.join(@admin_buildpacks_dir, b[:key]).to_s }
    end

    def all_buildpack_paths
      Pathname.new(@admin_buildpacks_dir).children.map(&:to_s)
    end

    def system_buildpack_paths
      Pathname.new(@system_buildpacks_dir).children.sort.map(&:to_s)
    end
  end
end