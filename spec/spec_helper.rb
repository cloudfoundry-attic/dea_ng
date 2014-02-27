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

module PlatformCompat
  VALID_PLATFORMS = [:Linux, :Windows].freeze

  # Useful for testing, but not really safe or useful for production code
  def self.platform=(value)
    raise StandardError.new("Invalid platform '#{value}'.") unless VALID_PLATFORMS.include?(value)
    @@platform = value
  end

  class PlatformContext
    def initialize(platform_to_set, platform_to_restore)
      @platform_to_set = platform_to_set
      @platform_to_restore = platform_to_restore
    end

    def self.enter(platform)
      context = PlatformContext.new(platform, PlatformCompat.platform)
      context.enter!
      context
    end

    def enter!
      PlatformCompat.platform = @platform_to_set
    end

    def exit!
      PlatformCompat.platform = @platform_to_restore
    end
  end
end

module PlatformSpecificExamples
  def platform_specific(symbol, opts = {})
    let(symbol) { opts[:default_platform] || :Linux }
    before {
      platform = self.public_send(symbol)
      @platform_context = PlatformCompat::PlatformContext.enter(platform)
    }
    after {
      @platform_context.exit! unless @platform_context.nil?
      @platform_context = nil
    }
  end
end

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

  config.extend(PlatformSpecificExamples)

  if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
    config.filter_run_excluding :unix_only => true
  else
    config.filter_run_excluding :windows_only => true
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
