require 'buildpack'
require 'rr'
require 'tempfile'

Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].map { |f| require f }

# Created as needed, removed at the end of the spec run.
# Allows us to override staging paths.
STAGING_TEMP = Dir.mktmpdir

RSpec.configure do |config|
  config.include StagingSpecHelpers
  config.mock_with :rr
end

at_exit do
  if File.directory?(STAGING_TEMP)
    FileUtils.rm_r(STAGING_TEMP)
  end
end
