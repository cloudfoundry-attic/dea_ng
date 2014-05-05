require "fileutils"

module Dea
  class StagingTaskWorkspace
    DROPLET_FILE = "droplet.tgz"
    BUILDPACK_CACHE_FILE = "buildpack_cache.tgz"
    STAGING_LOG = "staging_task.log"
    STAGING_INFO = "staging_info.yml"

    def initialize(base_dir)
      @base_dir = base_dir
    end

    def workspace_dir
      #return @workspace_dir if @workspace_dir
      #staging_base_dir = File.join(@base_dir, "staging")
      #@workspace_dir = Dir.mktmpdir(nil, staging_base_dir)
      #File.chmod(0755, @workspace_dir)
      #@workspace_dir

      @workspace_dir ||= begin
        staging_dir = File.join(@base_dir, "staging")
        FileUtils.mkdir_p(staging_dir)

        Dir.mktmpdir(nil, staging_dir).tap do |dir|
          File.chmod(0755, dir)
        end
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

    def warden_staging_log
      "/tmp/staged/logs/#{STAGING_LOG}"
    end

    def warden_staging_info
      "/tmp/#{STAGING_INFO}"
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

    def platform_config_path
      File.join(workspace_dir, "platform_config")
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
