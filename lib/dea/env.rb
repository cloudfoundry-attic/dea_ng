# coding: UTF-8

require "socket"
require "steno"
require "steno/core_ext"
require "yajl"

module Dea
  class Env
    attr_reader :instance

    def initialize(instance)
      @instance = instance
    end

    # The format used by VCAP_SERVICES
    def services_for_json
      whitelist = %W(
        name
        label
        tags
        plan
        plan_option
        credentials
      )

      services_hash = Hash.new { |h, k| h[k] = [] }

      instance.services.each do |service|
        service_hash = {}
        whitelist.each do |key|
          service_hash[key] = service[key] if service[key]
        end

        services_hash[service["label"]] << service_hash
      end

      services_hash
    end

    # The format used by VCAP_APPLICATION
    def application_for_json
      keys = %W[
        instance_id
        instance_index

        application_version
        application_name
        application_uris
      ]

      # TODO(kowshik): Eliminate application_users as it is deprecated.
      hash = { "application_users" => [] }

      keys.each do |key|
        hash[key] = instance.send(key)
      end

      started_at = Time.at(instance.state_starting_timestamp)

      hash["started_at"]           = started_at
      hash["started_at_timestamp"] = started_at.to_i
      hash["host"]                 = local_ip
      hash["http_port"]            = instance.instance_host_port
      hash["container_host"]       = instance.container.info.host_ip
      hash["container_http_port"]  = instance.instance_container_port
      hash["limits"]               = instance.limits

      # Translate keys for backwards compatibility
      hash["version"]         = hash["application_version"]
      hash["name"]            = hash["application_name"]
      hash["uris"]            = hash["application_uris"]
      hash["users"]           = hash["application_users"]

      hash["start"]           = hash["started_at"]
      hash["state_timestamp"] = hash["started_at_timestamp"]

      hash
    end

    def tcp_ports_env
      ports = []
      index = 1
      prod_ports = instance.instance_meta["prod_ports"]
      return ports if prod_ports.nil?
      prod_ports.each_pair do |k,v|
        if k != "sshd" && v["port_info"]["bns"] == true 
          ports << ["JPAAS_TCP_PORT_#{index}", v["host_port"]]
          ports << [k, v["container_port"] ]
          index += 1
        end
      end
      ports
    end

    def env
      application = application_for_json
      services    = services_for_json
      env = []
      env << ["JPAAS_APPLICATION",  Yajl::Encoder.encode(application)]
      env << ["JPAAS_SERVICES",     Yajl::Encoder.encode(services)]

      env << ["JPAAS_CONTAINER_HOST",       application["container_host"]]
      env << ["JPAAS_CONTAINER_HTTP_PORT",  instance.instance_container_port]

      env << ["JPAAS_HOST",          application["host"]]
      env << ["JPAAS_HTTP_PORT",     instance.instance_host_port]

      env << ["JPAAS_CONTAINER_CONSOLE_IP",   application["container_host"]]
      env << ["JPAAS_CONTAINER_CONSOLE_PORT", instance.instance_console_container_port]

      env << ["JPAAS_CONSOLE_IP",   application["host"]]
      env << ["JPAAS_CONSOLE_PORT", instance.instance_console_host_port]

      if instance.debug
        env << ["JPAAS_CONTAINER_DEBUG_IP",     application["container_host"]]
        env << ["JPAAS_CONTAINER_DEBUG_PORT",   instance.instance_debug_container_port]

        env << ["JPAAS_DEBUG_IP",     application["host"]]
        env << ["JPAAS_DEBUG_PORT",   instance.instance_debug_host_port]

        # Set debug environment for buildpacks to process
        env << ["JPAAS_DEBUG_MODE",   instance.debug]
      end

      env += tcp_ports_env unless tcp_ports_env.empty?

      # Wrap variables above in single quotes (no interpolation)
      env = env.map do |(key, value)|
        [key, %{'%s'} % value.to_s]
      end

      # Include user-specified environment
      env.concat(translate_env(instance.environment))

      env
    end

    def translate_env(env)
      return [] unless env
      env.map do |(key, value)|
        # Wrap value in double quotes if it isn't already (allows interpolation)
        unless value =~ /^['"]/
          value = %{"%s"} % value
        end

        [key, value]
      end
    end

    def local_ip
      begin
        ip = IPSocket.getaddress(Socket.gethostname)
      rescue SocketError
        ip = "0.0.0.0"
      end
      ip
    end

  end
end
