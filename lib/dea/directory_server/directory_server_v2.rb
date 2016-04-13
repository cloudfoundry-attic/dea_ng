# coding: UTF-8

require "dea/utils"
require "dea/directory_server/hmac_helper"

module Dea
  class DirectoryServerV2
    attr_reader :uuid, :domain, :port
    attr_reader :hmac_helper
    attr_reader :file_api_server

    def initialize(domain, port, router_client, config={})
      @uuid   = Dea.secure_uuid
      @domain = domain
      @port   = port
      @config = config
      @hmac_helper = HMACHelper.new(Dea.secure_uuid)
      @router_client = router_client
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
        Thin::Server.new("127.0.0.1", @config["directory_server"]["file_api_port"], helper_app, {signals: false})
    end

    def start
      raise ArgumentError, "file api server must be configured" unless @file_api_server
      @file_api_server.start
    end

    def hmaced_url_for(path, params={}, params_to_verify=[])
      verifiable_params = params.select { |k, v| params_to_verify.include?(k) }
      verifiable_path_and_params = "#{path}?#{params_to_s(verifiable_params)}"

      hmac = hmac_helper.create(verifiable_path_and_params)
      params_with_hmac = params_to_s(params.merge(:hmac => hmac))

      "#{@config["directory_server"]["protocol"]}://#{external_hostname}#{path}?#{params_with_hmac}"
    end

    def verify_hmaced_url(url, params_to_verify=[])
      parsed_url = URI.parse(url)
      params = Rack::Utils.parse_query(parsed_url.query)

      # Do not symbolize user input!
      params_to_verify = params_to_verify.map(&:to_s)
      verifiable_params = params.select { |k, v| params_to_verify.include?(k) }
      verifiable_path_and_params = "#{parsed_url.path}?#{params_to_s(verifiable_params)}"

      hmac_helper.compare(params["hmac"], verifiable_path_and_params)
    end

    VERIFIABLE_FILE_PARAMS = [:path, :timestamp]

    def instance_file_url_for(instance_id, file_path)
      hmaced_url_for(
        "/instance_paths/#{instance_id}",
        {:path => file_path, :timestamp => Time.now.to_i},
        VERIFIABLE_FILE_PARAMS
      )
    end

    def verify_instance_file_url(url)
      verify_hmaced_url(url, VERIFIABLE_FILE_PARAMS)
    end

    def staging_task_file_url_for(task_id, file_path)
      hmaced_url_for(
        "/staging_tasks/#{task_id}/file_path",
        {:path => file_path, :timestamp => Time.now.to_i},
        VERIFIABLE_FILE_PARAMS
      )
    end

    def verify_staging_task_file_url(url)
      verify_hmaced_url(url, VERIFIABLE_FILE_PARAMS)
    end

    def unregister
      @router_client.unregister_directory_server(port, external_hostname)
    end

    private

    def params_to_s(params)
      Rack::Utils.build_query(params.sort)
    end
  end
end

require "dea/directory_server/instance_paths"
require "dea/directory_server/staging_tasks"
