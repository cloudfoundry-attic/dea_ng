require 'eventmachine'
require 'nats/client'
require 'yajl'
require 'logger'

require 'vcap/dea/handler'
require 'vcap/dea/errors'
require 'vcap/dea/message'
require 'vcap/logging'

require 'vcap/dea/warden_env'

module VCAP
  module Dea
  end
end

class VCAP::Dea::Server

  EVACUATION_DELAY     = 30
  HEARTBEAT_INTERVAL   = 10
  ADVERTISE_INTERVAL   = 5
  WARDEN_PING_INTERVAL = 5
  VARZ_UPDATE_INTERVAL = 1
  CRASHED_APPS_CLEANUP_INTERVAL = 10 #XXX increase this for production.
  RESOURCE_USAGE_UPDATE_INTERVAL = 5

  attr_accessor :handler

  def initialize(nats_uri, handler, logger = nil)
    @logger   = logger || Logger.new(STDOUT)
    @nats_uri = nats_uri
    @handler  = handler
    @routes   = {}
    @sids     = []
    @shutting_down = false
    @logger.debug("server initialized.")
  end

  def evacuate_apps_then_quit
    return if @shutting_down
    @shutting_down = true
    msg = VCAP::Dea::Message.new(@nats)
    Fiber.new { @handler.evacuate_apps(msg) }.resume
    @logger.info("Scheduling shutdown in #{EVACUATION_DELAY} seconds..")
    EM.add_timer(EVACUATION_DELAY) { shutdown() }
  end

  def shutdown
    @shutting_down = true
    msg = VCAP::Dea::Message.new(@nats)
    @logger.info('Starting shutdown..')
    Fiber.new { @handler.shutdown(msg) }.resume
    EM.add_timer(0.25) do  #allow messages time to get out XXX crank this down
      NATS.stop { EM.stop }
      @logger.info('Shutdown complete..')
      exit
    end
  end

  def ping_warden
    Fiber.new {
      begin
        VCAP::Dea::WardenEnv.ping
      rescue => e
        @logger.error "Warden unreachable, shutting down:#{e.message}"
        shutdown
      end
    }.resume
  end

  #XXX - minor - refactor these two to remove duplication.
  def send_heartbeat
    return if @shutting_down
    msg = @handler.get_heartbeat
    if msg
      msg = VCAP::Dea::Message.new(@nats, 'dea.heartbeat', :details => msg)
      msg.send
    end
  end

  def send_advertise
    return if @shutting_down
    msg = @handler.get_advertise
    if msg
      msg = VCAP::Dea::Message.new(@nats, 'dea.advertise', :details => msg)
      msg.send
    end
  end

  def send_hello
    hello_msg = @handler.get_hello
    msg = VCAP::Dea::Message.new(@nats, 'dea.start',
                                 :details => hello_msg)
    msg.send
  end

  def setup_error_handling
    @nats.on_error do |e|
      @logger.error("EXITING! NATS error: #{e}")
      @logger.error(e)
      @handler.snapshot_and_exit
    end

    EM.error_handler do |e|
      @logger.error "Eventmachine problem, #{e}"
      @logger.error(e)
    end
  end

  def register_component
    VCAP::Component.register(:type => 'DEA',
                           :host => @handler.local_ip,
                           :index => '0', #XXX fixme
                           :config => {}, #XXX fixme
                           :port => 9999, #XXX fixme
                           :user => 'foo', #XXX fixme
                           :password => 'foo') #XXX fixme
    @uuid = VCAP::Component.uuid
    @handler.set_uuid(@uuid)
  end

  def resume_detached_containers
    Fiber.new { @handler.restore_snapshot }.resume
    Fiber.new { @handler.resume_detached_containers }.resume
  end

  def update_varz
    latest_varz = @handler.fetch_and_update_varz
    latest_varz.each { |key,value| VCAP::Component.varz[key] = value }
  end

  def start
    @logger.info("connecting to nats: #{@nats_uri}")
    @nats = NATS.start(:uri => @nats_uri) do
      register_component
      setup_error_handling
      resume_detached_containers
      setup_subscriptions
      setup_periodic_jobs
      send_hello
      send_advertise
      send_heartbeat
    end
  end

  private

  def setup_periodic_jobs
    #XXX fetch intervals from config file?
    EM.add_periodic_timer(WARDEN_PING_INTERVAL) { ping_warden    }
    EM.add_periodic_timer(ADVERTISE_INTERVAL)   { send_advertise }
    EM.add_periodic_timer(HEARTBEAT_INTERVAL)   { send_heartbeat }
    EM.add_periodic_timer(VARZ_UPDATE_INTERVAL) { update_varz    }
    EM.add_periodic_timer(RESOURCE_USAGE_UPDATE_INTERVAL) { Fiber.new { @handler.update_cached_resource_usage}.resume }
    EM.add_periodic_timer(RESOURCE_USAGE_UPDATE_INTERVAL) { Fiber.new { @handler.update_total_resource_usage}.resume }
    EM.add_periodic_timer(CRASHED_APPS_CLEANUP_INTERVAL)  { Fiber.new { @handler.remove_expired_crashed_apps }.resume }
  end

  def setup_subscriptions
    @handler_methods = {
      'healthmanager.start'   =>       :handle_hm_start,
      'router.start'          =>       :handle_router_start,
      'dea.status' =>                  :handle_status,
      "dea.#{@uuid}.start"  => :start_instance,
      'dea.locate' =>                  :handle_locate,
      'dea.stop'              =>       :handle_stop,
      'dea.update'            =>       :handle_update,
      'dea.find.droplet'      =>       :handle_find_droplet,
      'droplet.status'        =>       :handle_droplet_status,
    }
    @handler_methods.each do |subj, method|
      @sids << @nats.subscribe(subj) do |raw_msg, reply_to|
        dispatch(subj, raw_msg, reply_to)
      end
    end
  end

  # Decodes/dispatches messages received on *subj* to *handler*.
  #
  # @param  nats    NATS::Client  Nats client
  # @param  subj    String        Subject to subscribe to
  # @param  handler Symbol        Method that will handle the incoming message
  #
  # @return nil
  def dispatch(subj, raw_msg, reply_to)
    return if @shutting_down
    begin
      msg = VCAP::Dea::Message.decode_received(@nats, subj, raw_msg, reply_to)
    rescue => e
      @logger.error("Failed decoding '#{raw_msg}': #{e}")
      return
    end

    method = @handler_methods[subj]

    Fiber.new do
      begin
      @logger.debug("dispatching \'#{msg.details.to_s}\' to #{method}")
      @handler.send(method, msg)
      rescue VCAP::Dea::HandlerError => e
        @logger.error("Handler Error:#{e.message}")
        @logger.error e.backtrace.join("\n")
      end
    end.resume
    nil
  end

end
