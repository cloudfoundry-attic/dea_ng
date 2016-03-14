require 'dea/http/app_paths'

module Dea
  class HttpServer
    attr_reader :http_server, :port

    def initialize(bootstrap, config)
      ssl = config['ssl']
      if ssl
        raise ArgumentError, "port must be configured" unless ssl['port']
        @port = ssl['port']

        Dea::Http::AppPaths.configure(bootstrap)

        helper_app = Class.new(Grape::API) do
          mount Dea::Http::AppPaths
        end

        Thin::Logging.silent = true

        @http_server =
          Thin::Server.new('0.0.0.0', port, helper_app, { signals: false })

        @http_server.ssl = true
        @http_server.ssl_options = {
          private_key_file: ssl['key_file'],
          cert_chain_file: ssl['cert_file'],
          verify_peer: true,
        }
      end
    end

    def enabled?
      !@http_server.nil?
    end

    def start
      @http_server.start if @http_server
    end
  end
end
