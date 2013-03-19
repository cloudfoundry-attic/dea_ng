#!/usr/bin/env ruby

require "thin"
require "sinatra/base"

APPS_DIR = File.expand_path("../../fixtures/apps", __FILE__)
BUILDPACKS_DIR = File.expand_path("../../fixtures/fake_buildpacks", __FILE__)

class FileServer < Sinatra::Base
  get "/unstaged/:name" do |name|
    zip_path = "/tmp/fixture-#{name}.zip"
    Dir.chdir("#{APPS_DIR}/#{name}") do
      system "rm -rf #{zip_path} && zip #{zip_path} *"
    end
    send_file(zip_path)
  end

  post "/staged/:name" do |name|
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
