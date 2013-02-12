# coding: UTF-8

require "thin"
require "vcap/common"

require "dea/directory"

module Dea
  class DirectoryServer

    attr_reader :credentials
    attr_reader :port
    attr_reader :uri
    attr_reader :uuid

    def initialize(host, port, instance_registry)
      @host = host
      @port = port
      @uri = "http://#{host}:#{port}/instances"
      @credentials = [VCAP.secure_uuid, VCAP.secure_uuid]
      @instance_registry = instance_registry
      @uuid = VCAP.secure_uuid
      @server = create_server(host, port, @credentials, instance_registry)
    end

    def start
      @server.start!
    end

    private

    def create_server(host, port, creds, instance_registry)
      Thin::Server.new(host, port, :signals => false) do
        Thin::Logging.silent = true

        use Rack::Auth::Basic do |username, password|
          [username, password] == creds
        end

        map "/instances" do
          run Dea::Directory.new(instance_registry)
        end
      end
    end
  end
end
