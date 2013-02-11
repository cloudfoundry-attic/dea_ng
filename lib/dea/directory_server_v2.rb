# coding: UTF-8

require "vcap/common"
require "dea/hmac_helper"

module Dea
  class DirectoryServerV2
    attr_reader :uuid, :domain, :port
    attr_reader :hmac_helper
    attr_reader :file_api_server

    def initialize(domain, port, config={})
      @uuid   = VCAP.secure_uuid
      @domain = domain
      @port   = port
      @config = config
      @hmac_helper = HMACHelper.new(VCAP.secure_uuid)
    end

    def external_hostname
      "#{uuid}.#{domain}"
    end

    def configure_endpoints(instance_registry, staging_task_registry)
      Dea::DirectoryServerV2::InstancePaths.configure(self, instance_registry, 60 * 60)
      Dea::DirectoryServerV2::StagingTasks.configure(self, staging_task_registry, 60 * 60)

      helper_app = Class.new(Grape::API) do
        mount Dea::DirectoryServerV2::InstancePaths
        mount Dea::DirectoryServerV2::StagingTasks
      end

      Thin::Logging.silent = true

      @file_api_server =
        Thin::Server.new("127.0.0.1", @config["directory_server"]["file_api_port"], helper_app)
    end

    def start
      raise ArgumentError, "file api server must be configured" unless @file_api_server
      @file_api_server.start
    end

    def file_url_for(instance_id, file_path)
      url_for("/instance_paths/#{instance_id}", :path => file_path, :timestamp => Time.now.to_i)
    end

    def url_for(path, params = {})
      path_and_params = "#{path}?#{params_to_s(params)}"
      "http://#{external_hostname}#{path_and_params}&hmac=#{hmac_helper.create(path_and_params)}"
    end

    def verify_url(url)
      parsed_url = URI.parse(url)
      params = Rack::Utils.parse_query(parsed_url.query)

      given_hmac = params["hmac"]
      params.delete("hmac")

      path_and_params = "#{parsed_url.path}?#{params_to_s(params)}"
      hmac_helper.compare(given_hmac, path_and_params)
    end

    private

    def params_to_s(params)
      Rack::Utils.build_query(params.sort)
    end
  end
end

require "dea/directory_server/instance_paths"
require "dea/directory_server/staging_tasks"
