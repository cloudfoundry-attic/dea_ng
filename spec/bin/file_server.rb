#!/usr/bin/env ruby

require "thin"
require "sinatra/base"

class FileServer < Sinatra::Base
  APPS_DIR = File.expand_path("../../fixtures/apps", __FILE__)

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

FileServer.run!(:port => 9999)
