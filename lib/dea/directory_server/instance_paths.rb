# coding: UTF-8

require "grape"
require "steno"

class Dea::DirectoryServerV2
  class InstancePaths < Grape::API
    class << self
      def configure(directory_server, instance_registry, max_url_age_secs)
        global_setting(:directory_server, directory_server)
        global_setting(:instance_registry, instance_registry)
        global_setting(:max_url_age_secs, max_url_age_secs) # How long urls are valid for
      end
    end

    logger Steno.logger(self.class.name)

    format :json

    helpers do
      def json_error!(msg, status)
        error!({ "error" => msg }, status)
      end

      def check_url_age!(timestamp)
        url_age_secs = Time.now.to_i - timestamp.to_i
        max_age_secs = global_setting(:max_url_age_secs)

        if url_age_secs > max_age_secs
          logger.warn("Url too old (age=#{url_age_secs}s, max=#{max_age_secs})")
          json_error!("Url expired", 400)
        end
      end

      def logger
        InstancePaths.logger
      end
    end

    resource :instance_paths do
      params do
        requires :hmac, :type => String
        requires :timestamp, :type => Integer
        requires :path, :type => String
      end
      route_param :instance_id do
        get do
          unless global_setting(:directory_server).verify_instance_file_url(request.url)
            logger.warn("HMAC mismatch")
            json_error!("Invalid HMAC", 401)
          end

          check_url_age!(params[:timestamp])

          instance_id = params[:instance_id]
          instance    = global_setting(:instance_registry).lookup_instance(instance_id)
          if instance.nil?
            logger.warn("Unknown instance, instance_id=#{instance_id}")
            json_error!("Unknown instance", 404)
          end

          unless instance.instance_path_available?
            logger.warn("Instance path unavailable, instance_id=#{instance_id}")
            json_error!("Instance unavailable", 503)
          end

          full_path = File.join(instance.instance_path, params[:path].to_s)
          unless File.exists?(full_path)
            json_error!("Entity not found", 404)
          end

          # Expand symlinks and '..'
          real_path = File.realpath(full_path)
          unless real_path.start_with?(instance.instance_path)
            logger.warn("Requested path '#{full_path}' points outside instance to '#{real_path}'")
            json_error!("Not accessible", 403)
          end

          { "instance_path" => real_path }
        end
      end
    end
  end
end
