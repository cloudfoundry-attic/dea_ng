# coding: UTF-8

$:.unshift(File.expand_path("../../buildpacks/lib", __FILE__))

require 'bundler'
Bundler.require

require 'tempfile'
require 'timecop'
require 'timeout'
require_relative '../buildpacks/lib/buildpack'

Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].map { |f| require f }

RSpec.configure do |config|
  config.include Helpers
  config.include StagingSpecHelpers, :type => :buildpack
  config.include BuildpackHelpers, :type => :integration
  config.include ProcessHelpers, :type => :integration
  config.include DeaHelpers, :type => :integration

  config.before do
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

  config.before(:all, :type => :integration, :requires_warden => true) { dea_start }

  config.after(:all, :type => :integration, :requires_warden => true) { dea_stop }
end

STAGING_TEMP = Dir.mktmpdir

at_exit do
  if File.directory?(STAGING_TEMP)
    FileUtils.rm_r(STAGING_TEMP)
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