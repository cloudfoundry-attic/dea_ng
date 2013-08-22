#!/usr/bin/env ruby

# Read JSON from stdin. The JSON should look like:
# {
#   "warden_socket_path": "/tmp/warden.sock",
#   "bind_mounts": [
#     {"src_path": "/tmp/foo", "dst_path": "/bar", mode: "rw"}
#   ]
# }
#
# Then create a container with the specified bind mounts set up.
# Prints JSON to stdout that looks like:
# {
#   "handle": "abc123"
# }

require "json"

$:.unshift(File.expand_path("../../lib", __FILE__))
require "dea/container/container"
require "dea/container/connection_provider"

config = JSON.parse(STDIN.read)
warden_socket_path = config.fetch("warden_socket_path")
container = Dea::Container.new(Dea::ConnectionProvider.new(warden_socket_path))
container.sync_create_container(config.fetch("bind_mounts"))
puts({handle: container.handle}.to_json)