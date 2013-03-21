#!/usr/bin/env ruby

require "fileutils"
require "thin"
require "sinatra/base"
require "pp"

APPS_DIR = File.expand_path("../../fixtures/apps", __FILE__)
BUILDPACKS_DIR = File.expand_path("../../fixtures/fake_buildpacks", __FILE__)
STAGED_APPS_DIR = "/tmp/dea"
FileUtils.mkdir_p(STAGED_APPS_DIR)

class FileServer < Sinatra::Base
  get "/unstaged/:name" do |name|
    zip_path = "/tmp/fixture-#{name}.zip"
    Dir.chdir("#{APPS_DIR}/#{name}") do
      system "rm -rf #{zip_path} && zip #{zip_path} *"
    end
    send_file(zip_path)
  end

  post "/staged/:name" do |name|
    droplet = params["upload"]["droplet"]
    FileUtils.mv(droplet[:tempfile].path, file_path(name))
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

app = Rack::Builder.new do
  map "/buildpacks" do
    run Rack::Directory.new(BUILDPACKS_DIR)
  end

  run FileServer.new
end

$stdout.sync = true
Rack::Handler::Thin.run(app, :Port => 9999)
