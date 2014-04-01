require "dea/staging/admin_buildpack_downloader"

module Dea
  class BuildpackManager
    def initialize (admin_buildpacks_dir, system_buildpacks_dir, staging_message, buildpacks_in_use)
      @admin_buildpacks_dir = admin_buildpacks_dir
      @system_buildpacks_dir = system_buildpacks_dir
      @staging_message = staging_message
      @buildpacks_in_use = buildpacks_in_use
    end

    def download
      AdminBuildpackDownloader.new(@staging_message.admin_buildpacks, @admin_buildpacks_dir).download
    end

    def clean
      buildpack_paths_needing_deletion.each do |path|
        FileUtils.rm_rf(path)
      end
    end

    def buildpack_dirs
      admin_buildpacks + system_buildpacks
    end

    def buildpack_key(buildpack_dir)
      return nil unless buildpack_dir
      path = Pathname.new(buildpack_dir)
      return nil unless admin_buildpack_path?(path)
      path.basename.to_s
    end

    def system_buildpack_url(buildpack_dir)
      return nil unless buildpack_dir
      path = Pathname.new(buildpack_dir)
      return nil unless system_buildpack_path?(path)
      URI("buildpack:system:#{path.basename.to_s}")
    end

    private

    def buildpack_paths_needing_deletion
      local_admin_buildpack_paths - (admin_buildpacks.map{ |b| Pathname.new(b) } + buildpacks_in_use_paths)
    end

    def admin_buildpacks
      @staging_message.admin_buildpacks.map do |buildpack|
        File.join(@admin_buildpacks_dir, buildpack[:key])
      end.select{ |dir| File.exists?(dir) }.map(&:to_s)
    end

    def system_buildpacks
      system_buildpack_paths.map(&:to_s)
    end

    def buildpacks_in_use_paths
      @buildpacks_in_use.map { |b| Pathname.new(@admin_buildpacks_dir).join(b[:key]) }
    end

    def local_admin_buildpack_paths
      Pathname.new(@admin_buildpacks_dir).children
    end

    def system_buildpack_paths
      Pathname.new(@system_buildpacks_dir).children.sort
    end

    def admin_buildpack_path?(path)
      local_admin_buildpack_paths.include?(path)
    end

    def system_buildpack_path?(path)
      system_buildpack_paths.include?(path)
    end
  end
end
