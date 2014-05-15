module Buildpacks
  class StagingError < StandardError; end

  class NoAppDetectedError < StagingError; end
  class BuildpackCompileFailed < StagingError; end
  class BuildpackReleaseFailed < StagingError; end
end
