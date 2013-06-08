# coding: UTF-8

require "grape"
require "steno"

class Dea::DirectoryServerV2
  class StagingTasks < Grape::API
    class << self
      def configure(directory_server, staging_task_registry, max_url_age_secs)
        set(:directory_server, directory_server)
        set(:staging_task_registry, staging_task_registry)
        set(:max_url_age_secs, max_url_age_secs)
      end
    end

    logger Steno.logger(self.class.name)

    format :json

    helpers do
      def json_error!(msg, status)
        error!({"error" => msg}, status)
      end

      def check_url_age!(timestamp)
        url_age_secs = Time.now.to_i - timestamp.to_i
        max_age_secs = settings[:max_url_age_secs]

        if url_age_secs > max_age_secs
          logger.warn "staging-task.uri.too-old",
            :age => url_age_secs, :max => max_age_secs
          json_error!("Url expired", 400)
        end
      end

      def logger
        StagingTasks.logger
      end

      def settings
        StagingTasks.settings
      end
    end

    resource :staging_tasks do
      params do
        requires :hmac,      :type => String
        requires :timestamp, :type => Integer
        requires :path,      :type => String
      end
      get "/:task_id/file_path" do
        unless settings[:directory_server].verify_staging_task_file_url(request.url)
          logger.warn "staging-task.hmac.mismatch"
          json_error!("Invalid HMAC", 401)
        end

        check_url_age!(params[:timestamp])
        task_id = params[:task_id]

        unless task = settings[:staging_task_registry].registered_task(task_id)
          logger.warn "staging-task.unknown", :task_id => task_id
          json_error!("Unknown staging task", 404)
        end

        unless full_path = task.path_in_container(params[:path])
          logger.warn "staging-task.path.unavailable", :task_id => task_id
          json_error!("Staging task unavailable", 503)
        end

        unless File.exists?(full_path)
          json_error!("Entity not found", 404)
        end

        # Expand symlinks and '..'
        real_path = File.realpath(full_path)
        unless real_path.start_with?(full_path)
          logger.warn "staging-task.requested-path.invalid",
            :requested => full_path, :resolved => real_path

          json_error!("Not accessible", 403)
        end

        { "instance_path" => real_path }
      end
    end
  end
end
