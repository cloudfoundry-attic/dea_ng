#!/usr/bin/env ruby

require "thin"
require "sinatra/base"
require "pp"

class FileServer < Sinatra::Base
  APPS_DIR = File.expand_path("../../fixtures/apps", __FILE__)
  STAGED_APPS_DIR = "/tmp/dea"
  FileUtils.mkdir_p(STAGED_APPS_DIR)

  get "/unstaged/:name" do |name|
    zip_path = "/tmp/fixture-#{name}.zip"
    Dir.chdir("#{APPS_DIR}/#{name}") do
      system "rm -rf #{zip_path} && zip #{zip_path} *"
    end
    send_file(zip_path)
  end

  post "/staged/:name" do |name|
    droplet = params["upload"]["droplet"]
    droplet[:tempfile].mv(file_path(name))
    200
  end

  get "/staged/:name" do |name|
    send_file(file_path(name))
  end

  private

  def file_path(name)
    "#{STAGED_APPS_DIR}/#{name}"
  end
end

$stdout.sync = true
FileServer.run!(:port => 9999)
