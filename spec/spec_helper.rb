# coding: UTF-8

SPEC_ROOT = File.dirname(__FILE__)

$:.unshift(File.expand_path('../buildpacks/lib', SPEC_ROOT))

require 'bundler'
Bundler.require

require 'rspec/fire'
require 'socket'
require 'tempfile'
require 'timecop'
require 'timeout'
require_relative '../buildpacks/lib/buildpack'
require 'webmock/rspec'

Dir[File.join(SPEC_ROOT, 'support/**/*.rb')].map { |f| require f }

RSpec.configure do |config|
  config.include(Helpers)
  config.include(StagingSpecHelpers, type: :buildpack)
  config.include(BuildpackHelpers, type: :integration)
  config.include(ProcessHelpers, type: :integration)
  config.include(DeaHelpers, type: :integration)
  config.include(StagingHelpers, type: :integration)
  config.include(RSpec::Fire)

  config.before do
    WebMock.allow_net_connect!

    steno_config = {
      default_log_level: :all,
      codec: Steno::Codec::Json.new,
      context: Steno::Context::Null.new
    }

    if ENV.has_key?('V')
      steno_config[:sinks] = [Steno::Sink::IO.new(STDERR)]
    end

    Steno.init(Steno::Config.new(steno_config))
  end

  config.before(:all, type: :integration, requires_warden: true) do
    dea_start if ENV.has_key?('LOCAL_DEA')
  end

  config.after(:all, type: :integration, requires_warden: true) do
    dea_stop if ENV.has_key?('LOCAL_DEA')
  end

  config.before(:all, type: :integration) do
    WebMock.disable!

    start_file_server
  end

  config.after(:all, type: :integration) do
    stop_file_server
  end
end

#Timecop.safe_mode = true

TEST_TEMP = Dir.mktmpdir
FILE_SERVER_DIR = '/tmp/dea'

at_exit do
  if File.directory?(TEST_TEMP)
    FileUtils.rm_r(TEST_TEMP)
  end
end

def by(message)
  if block_given?
    yield
  else
    pending message
  end
end

alias and_by by

def fixture(path)
  File.join(SPEC_ROOT, 'fixtures', path)
end
