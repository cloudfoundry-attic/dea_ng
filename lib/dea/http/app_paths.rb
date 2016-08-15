# coding: UTF-8

require "grape"
require "steno"

class Dea::Http
  class AppPaths < Grape::API
    class << self
      def configure(bootstrap)
        global_setting(:bootstrap, bootstrap)
      end
    end

    version 'v1'
    content_type :json, 'application/json'
    format :json

    helpers do
      def json_error!(msg, status)
        error!({ "error" => msg }, status)
      end
    end

    def logger
      global_setting(:bootstrap).logger
    end

    resource :stage do
      post do
        data = env[Grape::Env::API_REQUEST_BODY]
        logger.debug('http.request.received', route: route.to_s, body: data)

        return status 503 if global_setting(:bootstrap).evac_handler.evacuating? || global_setting(:bootstrap).shutdown_handler.shutting_down?

        global_setting(:bootstrap).stage_app_request(data)

        status 202
      end
    end

    resource :apps do
      post do
        data = env[Grape::Env::API_REQUEST_BODY]
        logger.debug('http.request.received', route: route.to_s, body: data)

        return status 503 if global_setting(:bootstrap).evac_handler.evacuating? || global_setting(:bootstrap).shutdown_handler.shutting_down?

        global_setting(:bootstrap).start_app(data)

        status 202
      end
    end
  end
end
