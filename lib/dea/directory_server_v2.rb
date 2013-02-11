# coding: UTF-8

require "vcap/common"
require "dea/hmac_helper"
require "dea/file_api"

module Dea
  class DirectoryServerV2
    attr_reader :uuid, :domain, :port
    attr_reader :hmac_helper
    attr_reader :file_api_server

    def initialize(domain, port, instance_registry, config={})
      @uuid   = VCAP.secure_uuid
      @domain = domain
      @port   = port

      @instance_registry = instance_registry
      @config = config

      @hmac_helper = HMACHelper.new(VCAP.secure_uuid)
      configure_file_api_server
    end

    def external_hostname
      "#{uuid}.#{domain}"
    end

    def start
      @file_api_server.start
    end

    def file_url_for(instance_id, file_path)
      url_for("/instance_paths/#{instance_id}", :path => file_path, :timestamp => Time.now.to_i)
    end

    def url_for(path, params = {})
      non_hmaced_url = "http://#{external_hostname}#{path}?#{params_to_s(params)}"
      non_hmaced_url + "&hmac=#{hmac_helper.create(non_hmaced_url)}"
    end

    def verify_url(url)
      parsed_url = URI.parse(url)
      params = Rack::Utils.parse_query(parsed_url.query)
      given_hmac = params["hmac"]

      params.delete("hmac")
      parsed_url.query = params_to_s(params)
      hmac_helper.compare(given_hmac, parsed_url.to_s)
    end

    private

    def configure_file_api_server
      Dea::FileApi.configure(self, @instance_registry, 60 * 60)
      Thin::Logging.silent = true
      @file_api_server = Thin::Server.new("127.0.0.1", @config["directory_server"]["file_api_port"], Dea::FileApi)
    end

    def params_to_s(params)
      Rack::Utils.build_query(params.sort)
    end
  end
end
