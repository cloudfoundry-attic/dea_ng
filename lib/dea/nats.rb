# coding: UTF-8

require "dea/utils/uri_cleaner"
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

      subscribe("router.start") do |_|
        bootstrap.handle_router_start
      end

      subscribe("dea.status") do |message|
        bootstrap.handle_dea_status(message)
      end

      subscribe("dea.#{bootstrap.uuid}.start") do |message|
        bootstrap.handle_dea_directed_start(message)
      end

      subscribe("dea.stop") do |message|
        bootstrap.handle_dea_stop(message)
      end

      subscribe("dea.update") do |message|
        bootstrap.handle_dea_update(message)
      end

      subscribe("dea.find.droplet") do |message|
        bootstrap.handle_dea_find_droplet(message)
      end
    end

    def stop
      @sids.each { |_, sid| client.unsubscribe(sid) }
      @sids = {}
    end

    def flush(&block)
      client.flush(&block)
    end

    def publish(subject, data)
      client.publish(subject, Yajl::Encoder.encode(data))
    end

    def request(subject, data = {})
      client.request(subject, Yajl::Encoder.encode(data)) do |raw_data, respond_to|
        begin
          yield handle_incoming_message("response to #{subject}", raw_data, respond_to)
        rescue => e
          logger.error("nats.request.failed", subject: subject, data: raw_data)
        end
      end
    end

    def subscribe(subject, opts={})
      # Do not track subscription option is used with responders
      # since we want them to be responsible for subscribe/unsubscribe.
      do_not_track_subscription = opts.delete(:do_not_track_subscription)

      sid = client.subscribe(subject, opts) do |raw_data, respond_to|
        begin
          yield handle_incoming_message(subject, raw_data, respond_to)
        rescue Yajl::ParseError => e
          logger.error("nats.subscription.json_error", error: e, backtrace: e.backtrace)
        rescue => e
          logger.error("nats.subscription.error", subject: subject, data: raw_data, respond_to: respond_to, error: e, backtrace: e.backtrace)
        end
      end

      @sids[subject] = sid unless do_not_track_subscription
      sid
    end

    def unsubscribe(sid)
      client.unsubscribe(sid)
    end

    def client
      @client ||= create_nats_client
    end

    def create_nats_client
      clean_servers = URICleaner.clean(config["nats_servers"])
      logger.info("nats.connecting", servers: clean_servers)

      ::NATS.connect(
        :servers => config["nats_servers"],
        :max_reconnect_attempts => -1,
        :dont_randomize_servers => false,
      )
    end

    class Message
      def self.decode(nats, subject, raw_data, respond_to)
        data = Yajl::Parser.parse(raw_data)
        new(nats, subject, data, respond_to)
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

    def handle_incoming_message(subject, raw_data, respond_to)
      message = Message.decode(self, subject, raw_data, respond_to)
      logger.debug("nats.message.received", subject: subject, data: message.data)
      message
    end

    def logger
      @logger ||= self.class.logger
    end
  end
end
