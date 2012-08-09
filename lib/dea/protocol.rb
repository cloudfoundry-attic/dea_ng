require "dea/version"

module Dea
  module Protocol
  end
end

module Dea::Protocol::V1
  class HeartbeatResponse
    def self.generate(bootstrap, instances)
      hbs = instances.map do |instance|
        { "droplet"         => instance.application_id,
          "version"         => instance.application_version,
          "instance"        => instance.instance_id,
          "index"           => instance.instance_index,
          "state"           => instance.state,
          "state_timestamp" => instance.state_timestamp,
        }
      end

      { "droplets" => hbs,
        "dea"      => bootstrap.uuid,
      }
    end
  end

  class FindDropletResponse
    def self.generate(bootstrap, instance, include_stats)
      response = {
        "dea"             => bootstrap.uuid,
        "droplet"         => instance.application_id,
        "version"         => instance.application_version,
        "instance"        => instance.instance_id,
        "index"           => instance.instance_index,
        "state"           => instance.state,
        "state_timestamp" => instance.state_timestamp,
        "file_uri"        => bootstrap.directory_server.uri,
        "credentials"     => bootstrap.directory_server.credentials,
        "staged"          => "/#{instance.instance_id}",
      }

      if instance.debug
        response.update({
          "debug_ip"   => bootstrap.local_ip,
          "debug_port" => instance.instance_debug_host_port,
        })
      end

      if instance.console
        response.update({
          "console_ip"   => bootstrap.local_ip,
          "console_port" => instance.instance_console_host_port,
        })
      end

      if include_stats
        response["stats"] = {
          "name" => instance.application_name,
          "uris" => instance.application_uris,

          # TODO: Include once start command is hooked up
          # host
          # port
          # uptime
          # mem_quota
          # disk_quota
          # cores
        }
      end

      response
    end
  end

  class DropletStatusResponse
    def self.generate(instance)
      { "name" => instance.application_name,
        "uris" => instance.application_uris,
        # TODO: Fill in when available
        # host
        # port
        # uptime
      }
    end
  end

  class AdvertiseMessage
    def self.generate(bootstrap)
      { "id"       => bootstrap.uuid,
        "runtimes" => bootstrap.runtimes.keys,
        # TODO: Fill in when available
        "available_memory" => 0,
      }
    end
  end

  class HelloMessage
    def self.generate(bootstrap)
      { "id"   => bootstrap.uuid,
        "ip"   => bootstrap.local_ip,
        "port" => bootstrap.directory_server.port,
        "version" => Dea::VERSION,
      }
    end
  end

  class DeaStatusResponse
    def self.generate(bootstrap)
      hello = HelloMessage.generate(bootstrap)

      extra = {
        # TODO: Fill these in when we have resource tracking working
        "max_memory"      => nil,
        "reserved_memory" => nil,
        "used_memory"     => nil,
        "num_clients"     => nil,
      }

      hello.merge(extra)
    end
  end
end
