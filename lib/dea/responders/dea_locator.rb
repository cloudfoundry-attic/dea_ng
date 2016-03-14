require "dea/protocol"

module Dea::Responders
  class DeaLocator
    DEFAULT_ADVERTISE_INTERVAL = 5

    attr_reader :nats, :dea_id, :resource_manager
    attr_reader :stacks, :zone, :url


    def initialize(nats, dea_id, resource_manager, config, url)
      @nats = nats
      @dea_id = dea_id
      @resource_manager = resource_manager
      @stacks = config["stacks"].map { |stack| stack['name'] } || []
      @zone = config["placement_properties"]["zone"]
      @advertise_interval = config["intervals"]["advertise"] || DEFAULT_ADVERTISE_INTERVAL
      @url = url
    end

    def start
      start_periodic_dea_advertise
    end

    def stop
      stop_periodic_dea_advertise
    end

    def advertise
      nats.publish(
        "dea.advertise",
        Dea::Protocol::V1::AdvertiseMessage.generate(
          id: dea_id,
          url: url,
          stacks: stacks,
          available_memory: resource_manager.remaining_memory,
          available_disk: resource_manager.remaining_disk,
          app_id_to_count: resource_manager.app_id_to_count,
          placement_zone: zone,
        ),
      )
    rescue => e
      logger.error("dea_locator.advertise", error: e, backtrace: e.backtrace)
    end

    private

    # Cloud controller uses dea.advertise to
    # keep track of all deas that it can use to run apps
    def start_periodic_dea_advertise
      @advertise_timer = EM.add_periodic_timer(@advertise_interval) { advertise }
    end

    def stop_periodic_dea_advertise
      EM.cancel_timer(@advertise_timer) if @advertise_timer
    end
  end
end
