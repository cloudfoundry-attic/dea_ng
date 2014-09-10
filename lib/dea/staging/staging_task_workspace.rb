require "fileutils"
require "dea/staging/buildpack_manager"

module Dea
  class StagingTaskWorkspace
    DROPLET_FILE = "droplet.tgz".freeze
    BUILDPACK_CACHE_FILE = "buildpack_cache.tgz".freeze
    STAGING_LOG = "staging_task.log".freeze
    STAGING_INFO = "staging_info.yml".freeze

    def initialize(base_dir, properties)
      @base_dir = base_dir
      @environment_properties = properties
    end

    ###### Setup

    def workspace_dir
      @workspace_dir ||= begin
        staging_dir = File.join(@base_dir, "staging")
        FileUtils.mkdir_p(staging_dir)

        Dir.mktmpdir(nil, staging_dir).tap do |dir|
          File.chmod(0755, dir)
        end
      end
    end

    def write_config_file(buildpack_dirs)
      plugin_config = {
        "source_dir" => warden_unstaged_dir,
        "dest_dir" => warden_staged_dir,
        "cache_dir" => warden_cache,
        "environment" => @environment_properties,
        "staging_info_path" => warden_staging_info,
        "buildpack_dirs" => buildpack_dirs
      }

      logger.debug plugin_config
      File.open(plugin_config_path, 'w') { |f| YAML.dump(plugin_config, f) }
    end

    private :write_config_file

    def prepare(buildpack_manager)
      FileUtils.mkdir_p(tmpdir)
      buildpack_manager.download
      buildpack_manager.clean
      write_config_file(buildpack_manager.buildpack_dirs)
    end

    ###### Accessors

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

    def tmpdir
      File.join(@base_dir, "tmp")
    end

    def admin_buildpacks_dir
      File.join(@base_dir, "admin_buildpacks")
    end

    def buildpack_dir
      File.expand_path("../../../../buildpacks", __FILE__)
    end

    def system_buildpacks_dir
      File.join(buildpack_dir, "vendor")
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

    def downloaded_app_package_path
      File.join(workspace_dir, "app.zip")
    end

    def downloaded_buildpack_cache_path
      File.join(workspace_dir, BUILDPACK_CACHE_FILE)
    end
  end
end
