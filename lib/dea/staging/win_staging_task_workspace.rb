require "fileutils"
require "dea/staging/staging_task_workspace"

module Dea
  class WinStagingTaskWorkspace < StagingTaskWorkspace

    def warden_staged_droplet
      "@ROOT@/tmp/#{DROPLET_FILE}"
    end

    def warden_unstaged_buildpack_cache
      "@ROOT@/tmp/#{BUILDPACK_CACHE_FILE}"
    end

    def warden_staged_buildpack_cache
      "@ROOT@/tmp/#{BUILDPACK_CACHE_FILE}"
    end

    def warden_cache
      "@ROOT@/tmp/cache"
    end

    def warden_unstaged_dir
      "@ROOT@/tmp/unstaged"
    end

    def warden_staged_dir
      "@ROOT@/tmp/staged"
    end

    def warden_staging_log
      "@ROOT@/tmp/staged/logs/#{STAGING_LOG}"
    end

    def warden_staging_info
      #"@ROOT@/tmp/#{STAGING_INFO}"
      "@ROOT@/tmp/staged/#{STAGING_INFO}"
    end

  end
end
