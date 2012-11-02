# coding: UTF-8

require "vcap/common"

# Dummy class for encapsulating state related to the Go based server.
module Dea
  class DirectoryServerV2

    attr_reader :domain
    attr_reader :port
    attr_reader :uuid

    def initialize(domain, port)
      @uuid   = VCAP.secure_uuid
      @domain = domain
      @port   = port
    end

    def external_hostname
      "#{uuid}.#{domain}"
    end
  end
end
