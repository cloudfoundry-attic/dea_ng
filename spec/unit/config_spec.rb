$:.unshift(File.dirname(__FILE__))
require 'fileutils'
require 'spec_helper'
require 'config'

describe VCAP::Dea::Config do
  it "should parse a config file" do
    config_file = VCAP::Dea::Config::DEFAULT_CONFIG_PATH
    config = VCAP::Dea::Config.from_file(config_file)
    config.should_not == nil
  end
end
