# coding: UTF-8

require "vcap/common"
require "dea/hmac_helper"

module Dea
  class DirectoryServerV2
    attr_reader :domain
    attr_reader :port
    attr_reader :uuid
    attr_reader :hmac_helper

    def initialize(domain, port, config={})
      @uuid   = VCAP.secure_uuid
      @domain = domain
      @port   = port
      @hmac_helper = HMACHelper.new(config[:path_key])
    end

    def external_hostname
      "#{uuid}.#{domain}"
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

    def params_to_s(params)
      Rack::Utils.build_query(params.sort)
    end
  end
end
