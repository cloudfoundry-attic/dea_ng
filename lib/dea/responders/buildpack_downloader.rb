require 'dea/staging/staging_task'
require 'dea/staging/buildpacks_message'
require 'dea/loggregator'

module Dea::Responders
  class BuildpackDownloader
    attr_reader :nats
    attr_reader :config

    def initialize(nats, config)
      @nats = nats
      @config = config
    end

    def start
      return unless configured_to_stage?
      subscribe
    end

    def stop
      unsubscribe
    end

    def handle(message)
      buildpacks = BuildpacksMessage.new(message.data).buildpacks
      logger.debug('buildpacks.handle.start', request: message.inspect)

      Dea::Promise.resolve(promise_download_buildpacks(buildpacks)) do |error, _|
        if error
          logger.error('buildpacks.handle.failed', error: error, backtrace: error.backtrace)
        else
          logger.debug("buildpacks.handle.finished")
        end
      end
    end

    private

    def promise_download_buildpacks(buildpacks)
      Dea::Promise.new do |p|
        download_buildpacks(buildpacks, admin_buildpacks_dir)
        p.deliver
      end
    end

    def download_buildpacks(buildpacks, dest_dir)
      AdminBuildpackDownloader.new(buildpacks, dest_dir, logger).download
    end

    def admin_buildpacks_dir
      File.join(base_dir, "admin_buildpacks")
    end

    def base_dir
      @config["base_dir"]
    end

    def configured_to_stage?
      config['staging'] && config['staging']['enabled']
    end

    def subscribe
      @subscription_id =
        nats.subscribe('buildpacks', do_not_track_subscription: true) { |response| handle(response) }
    end

    def unsubscribe
      nats.unsubscribe(@subscription_id) if @subscription_id
    end

    def logger
      Steno::Logger.new("Staging", Steno.config.sinks, level: Steno.config.default_log_level)
    end
  end
end
