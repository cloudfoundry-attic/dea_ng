require "fileutils"
require "dea/admin_buildpack_downloader"

module Dea
  class StagingTaskWorkspace
    DROPLET_FILE = "droplet.tgz"
    BUILDPACK_CACHE_FILE = "buildpack_cache.tgz"
    STAGING_LOG = "staging_task.log"
    STAGING_INFO = "staging_info.yml"

    def initialize(base_dir, admin_buildpacks, buildpacks_in_use, environment_properties)
      @base_dir = base_dir
      @admin_buildpacks = admin_buildpacks || []
      @buildpacks_in_use = buildpacks_in_use
      @environment_properties = environment_properties
      FileUtils.mkdir_p(tmpdir)
      FileUtils.mkdir_p(admin_buildpacks_dir)
    end

    def workspace_dir
      @workspace_dir ||= begin
        staging_dir = File.join(@base_dir, "staging")
        FileUtils.mkdir_p(staging_dir)

        Dir.mktmpdir(nil, staging_dir).tap do |dir|
          File.chmod(0755, dir)
        end
      end
    end

    def write_config_file
      plugin_config = {
        "source_dir" => warden_unstaged_dir,
        "dest_dir" => warden_staged_dir,
        "cache_dir" => warden_cache,
        "environment" => @environment_properties,
        "staging_info_name" => STAGING_INFO,
        "buildpack_dirs" => filtered_admin_buildpack_paths + system_buildpack_paths
      }
      logger.info plugin_config
      File.open(plugin_config_path, 'w') { |f| YAML.dump(plugin_config, f) }
    end

    def prepare
      download_admin_buildpacks
      cleanup_admin_buildpacks
      write_config_file
    end

    def download_admin_buildpacks
      AdminBuildpackDownloader.new(
        @admin_buildpacks,
        admin_buildpacks_dir
      ).download
    end

    def cleanup_admin_buildpacks
      buildpacks_needing_deletion.each do |path|
        FileUtils.rm_rf(path)
      end
    end

    def warden_staged_droplet
      "/tmp/#{DROPLET_FILE}"
    end

    def warden_unstaged_buildpack_cache
      "/tmp/#{BUILDPACK_CACHE_FILE}"
    end

    def warden_staged_buildpack_cache
      "/tmp/#{BUILDPACK_CACHE_FILE}"
    end

    def warden_cache
      "/tmp/cache"
    end

    def warden_unstaged_dir
      "/tmp/unstaged"
    end

    def warden_staged_dir
      "/tmp/staged"
    end

    def admin_buildpacks_dir
      File.join(@base_dir, "admin_buildpacks")
    end

    def tmpdir
      File.join(@base_dir, "tmp")
    end

    def buildpack_dir
      File.expand_path("../../../buildpacks", __FILE__)
    end

    def system_buildpack_paths
      Pathname.new(File.join(buildpack_dir, "vendor")).children.map(&:to_s)
    end

    def filtered_admin_buildpack_paths
      Pathname.new(admin_buildpacks_dir).children.select do |s|
        @admin_buildpacks.detect do |buildpack|
          buildpack["key"] == File.basename(s)
        end
      end.map(&:to_s)
    end

    def buildpacks_needing_deletion
      all_buildpack_paths - (filtered_admin_buildpack_paths + buildpacks_in_use_paths)
    end

    def all_buildpack_paths
      Pathname.new(admin_buildpacks_dir).children.map(&:to_s)
    end

    def buildpacks_in_use_paths
      @buildpacks_in_use.map { |b| File.join(admin_buildpacks_dir, b).to_s }
    end

    def warden_staging_log
      "#{warden_staged_dir}/logs/#{STAGING_LOG}"
    end

    def warden_staging_info
      "#{warden_staged_dir}/#{STAGING_INFO}"
    end

    def staged_droplet_path
      File.join(staged_droplet_dir, DROPLET_FILE)
    end

    def staged_buildpack_cache_path
      File.join(staged_droplet_dir, BUILDPACK_CACHE_FILE)
    end

    def staged_droplet_dir
      File.join(workspace_dir, "staged")
    end

    def staging_log_path
      File.join(workspace_dir, STAGING_LOG)
    end

    def plugin_config_path
      File.join(workspace_dir, "plugin_config")
    end

    def staging_info_path
      File.join(workspace_dir, STAGING_INFO)
    end

    def downloaded_droplet_path
      File.join(workspace_dir, "app.zip")
    end

    def downloaded_buildpack_cache_path
      File.join(workspace_dir, BUILDPACK_CACHE_FILE)
    end
  end
end
