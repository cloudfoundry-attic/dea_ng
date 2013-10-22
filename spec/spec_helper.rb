# coding: UTF-8

$:.unshift(File.expand_path("../../buildpacks/lib", __FILE__))

require 'bundler'
Bundler.require

require 'tempfile'
require 'timecop'
require 'timeout'
require 'socket'
require_relative '../buildpacks/lib/buildpack'
require "webmock/rspec"

Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].map { |f| require f }

RSpec.configure do |config|
  config.include Helpers
  config.include StagingSpecHelpers, :type => :buildpack
  config.include BuildpackHelpers, :type => :integration
  config.include ProcessHelpers, :type => :integration
  config.include DeaHelpers, :type => :integration
  config.include StagingHelpers, :type => :integration

  config.before do
    WebMock.allow_net_connect!

    RSpecRandFix.call_kernel_srand # TODO: remove this once we have a fix

    steno_config = {
      :default_log_level => :all,
      :codec => Steno::Codec::Json.new,
      :context => Steno::Context::Null.new
    }

    if ENV.has_key?("V")
      steno_config[:sinks] = [Steno::Sink::IO.new(STDERR)]
    end

    Steno.init(Steno::Config.new(steno_config))
  end

  config.before(:all, :type => :integration, :requires_warden => true) do
    dea_start if ENV.has_key?("LOCAL_DEA")
  end

  config.after(:all, :type => :integration, :requires_warden => true) do
    dea_stop if ENV.has_key?("LOCAL_DEA")
  end

  config.before(:all, :type => :integration) do
    WebMock.disable!

    start_file_server
  end

  config.after(:all, :type => :integration) do
    stop_file_server
  end

  if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
    config.filter_run_excluding :unix_only => true
  else
    config.filter_run_excluding :windows_only => true
  end
end

TEST_TEMP = Dir.mktmpdir
FILE_SERVER_DIR = "/tmp/dea"

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
  File.expand_path("../fixtures/#{path}", __FILE__)
end
