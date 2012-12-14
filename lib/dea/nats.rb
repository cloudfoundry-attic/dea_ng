# coding: UTF-8

require "steno"
require "steno/core_ext"
require "nats/client"

module Dea
  class Nats
    attr_reader :bootstrap
    attr_reader :config
    attr_reader :sids

    def initialize(bootstrap, config)
      @bootstrap = bootstrap
      @config    = config
      @sids      = {}
      @client    = nil
    end

    def start
      subscribe("healthmanager.start") do |message|
        bootstrap.handle_health_manager_start(message)
      end

      subscribe("router.start") do |message|
        bootstrap.handle_router_start(message)
      end

      subscribe("dea.status") do |message|
        bootstrap.handle_dea_status(message)
      end

      subscribe("dea.#{bootstrap.uuid}.start") do |message|
        bootstrap.handle_dea_directed_start(message)
      end

      subscribe("dea.locate") do |message|
        bootstrap.handle_dea_locate(message)
      end

      subscribe("dea.stop") do |message|
        bootstrap.handle_dea_stop(message)
      end

      subscribe("dea.discover") do |message|
        bootstrap.handle_dea_discover(message)
      end

      subscribe("dea.update") do |message|
        bootstrap.handle_dea_update(message)
      end

      subscribe("dea.find.droplet") do |message|
        bootstrap.handle_dea_find_droplet(message)
      end

      subscribe("droplet.status") do |message|
        bootstrap.handle_droplet_status(message)
      end
    end

    def stop
      @sids.each { |_, sid| client.unsubscribe(sid) }
      @sids = {}
    end

    def publish(subject, data)
      client.publish(subject, Yajl::Encoder.encode(data))
    end

    def subscribe(subject)
      sid = client.subscribe(subject) do |raw_data, respond_to|
        message = Message.decode(self, subject, raw_data, respond_to)
        logger.debug "Received on #{subject.inspect}: #{message.data.inspect}"
        yield message
      end

      @sids[subject] = sid
    end

    def client
      @client ||= create_nats_client
    end

    def create_nats_client
      logger.info "Connecting to NATS on #{config["nats_uri"]}"
      ::NATS.connect(:uri => config["nats_uri"])
    end

    class Message
      def self.decode(nats, subject, raw_data, respond_to)
        new(nats, subject, raw_data, respond_to)
      end

      attr_reader :nats
      attr_reader :subject
      attr_reader :data
      attr_reader :respond_to

      def initialize(nats, subject, data, respond_to)
        @nats       = nats
        @subject    = subject
        @data       = data
        @respond_to = respond_to
      end

      def respond(data)
        message = response(data)
        message.publish
      end

      def response(data)
        self.class.new(nats, respond_to, data, nil)
      end

      def publish
        nats.publish(subject, data)
      end
    end

    private

    def logger
      @logger ||= self.class.logger
    end
  end
end
