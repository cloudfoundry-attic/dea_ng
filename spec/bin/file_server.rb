#!/usr/bin/env ruby

require "thin"

PORT = ARGV[0]
raise "Pass a port!" unless PORT

app = Rack::Directory.new(File.expand_path("../../fixtures", __FILE__))
Rack::Handler::Thin.run(app, :Port => PORT)