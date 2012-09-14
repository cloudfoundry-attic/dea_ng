# coding: UTF-8

require "grape"
require "openssl"
require "steno"
require "steno/core_ext"

module Dea
  class FileApi < Grape::API

    class << self
      # @param [Dea::InstanceRegistry] instance_registry
      # @param [String] path_key  Key used for HMAC generation
      # @param [Integer] max_url_age_secs  How long urls are valid for
      def configure(instance_registry, path_key, max_url_age_secs)
        set(:instance_registry, instance_registry)
        set(:path_key, path_key)
        set(:max_url_age_secs, max_url_age_secs)
      end

      def create_hmac_hexdigest(instance_id, path, timestamp)
        hmac = OpenSSL::HMAC.new(settings[:path_key], OpenSSL::Digest::SHA512.new)

        [instance_id, path, timestamp.to_i.to_s].each { |x| hmac << x }

        hmac.hexdigest
      end

      def verify_hmac_hexdigest(hexdigest, other_hexdigest = "")
        return false if hexdigest.size != other_hexdigest.size

        # We explicity do not short circuit here in order to avoid a timing
        # attack.
        verified = true
        hexdigest.bytes.zip(other_hexdigest.bytes) do |expected_byte, given_byte|
          verified = false if expected_byte != given_byte
        end

        verified
      end

      def generate_file_url(instance_id, path)
        ts = Time.now.to_i
        hmac = create_hmac_hexdigest(instance_id, path, ts)
        "/instance_paths/#{instance_id}?timestamp=#{ts}&hmac=#{hmac}&path=#{path}"
      end
    end

    format :json
    error_format :json

    helpers do
      def json_error!(msg, status)
        error!({ "error" => msg }, status)
      end

      def verify_hmac!(given_hmac, instance_id, path, timestamp)
        expected_hmac = Dea::FileApi.create_hmac_hexdigest(instance_id, path, timestamp)
        if !Dea::FileApi.verify_hmac_hexdigest(expected_hmac, given_hmac)
          logger.warn("HMAC mismatch")
          json_error!("Invalid HMAC", 401)
        end
      end

      def check_url_age!(timestamp)
        url_age_secs = Time.now.to_i - timestamp.to_i
        max_age_secs = Dea::FileApi.settings[:max_url_age_secs]
        if url_age_secs > max_age_secs
          logger.warn("Url too old (age=#{url_age_secs}s, max=#{max_age_secs})")
          json_error!("Url expired", 400)
        end
      end

      def logger
        Dea::FileApi.logger
      end
    end

    resource :instance_paths do
      params do
        requires :hmac,      :type => String
        requires :timestamp, :type => Integer
        requires :path,      :type => String
      end
      get "/:instance_id" do
        instance_id = params[:instance_id]
        path = params[:path]
        ts = params[:timestamp]

        verify_hmac!(params[:hmac], instance_id, path, ts)

        check_url_age!(ts)

        # Lookup and verify path
        instance = Dea::FileApi.
          settings[:instance_registry].
          lookup_instance(instance_id)

        if instance.nil?
          logger.warn("Unknown instance, instance_id=#{instance_id}")
          json_error!("Unknown instance", 404)
        end

        if !instance.instance_path_available?
          logger.warn("Instance path unavailable, instance_id=#{instance_id}")
          json_error!("Instance unavailable", 503)
        end

        { "instance_path" => File.join(instance.instance_path, path) }
      end
    end

  end
end
