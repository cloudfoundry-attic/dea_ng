require "dea/protocol"

module Dea::Responders
  class StagingLocator
    DEFAULT_ADVERTISE_INTERVAL = 5

    attr_reader :nats
    attr_reader :dea_id
    attr_reader :resource_manager
    attr_reader :config

    def initialize(nats, dea_id, resource_manager, config)
      @nats = nats
      @dea_id = dea_id
      @resource_manager = resource_manager
      @config = config
    end

    def start
      start_periodic_staging_advertise
    end

    def stop
      stop_periodic_staging_advertise
    end

    def advertise
      # Currently we are not tracking memory used by
      # staging task, therefore, available_memory
      # is not accurate since it only account for running apps.
      nats.publish("staging.advertise", {
        "id" => dea_id,
        "stacks" => config["stacks"].map { |stack| stack['name'] },
        "available_memory" => resource_manager.remaining_memory,
        "available_disk" => resource_manager.remaining_disk,
      })
    rescue => e
      logger.error("staging_locator.advertise", error: e, backtrace: e.backtrace)
    end

    private

    # Cloud controller uses staging.advertise to
    # keep track of all deas that it can use to run apps
    def start_periodic_staging_advertise
      advertise_interval = config["intervals"]["advertise"] || DEFAULT_ADVERTISE_INTERVAL
      @advertise_timer = EM.add_periodic_timer(advertise_interval) { advertise }
    end

    def stop_periodic_staging_advertise
      EM.cancel_timer(@advertise_timer) if @advertise_timer
    end
  end
end
