# coding: UTF-8

require "dea/file_api"
require "dea/version"

module Dea
  module Protocol
  end
end

module Dea::Protocol::V1
  class HeartbeatResponse
    def self.generate(bootstrap, instances)
      hbs = instances.map do |instance|
        {
          "cc_partition"    => instance.cc_partition,
          "droplet"         => instance.application_id,
          "version"         => instance.application_version,
          "instance"        => instance.instance_id,
          "index"           => instance.instance_index,
          "state"           => Dea::Instance::State.to_external(instance.state),
          "state_timestamp" => instance.state_timestamp,
        }
      end

      { "droplets" => hbs,
        "dea"      => bootstrap.uuid,
        "prod"     => bootstrap.config.only_production_apps?,
      }
    end
  end

  class FindDropletResponse
    def self.generate(bootstrap, instance, request)
      response = {
        "dea"             => bootstrap.uuid,
        "droplet"         => instance.application_id,
        "version"         => instance.application_version,
        "instance"        => instance.instance_id,
        "index"           => instance.instance_index,
        "state"           => Dea::Instance::State.to_external(instance.state),
        "state_timestamp" => instance.state_timestamp,
        "file_uri"        => bootstrap.directory_server.uri,
        "credentials"     => bootstrap.directory_server.credentials,
        "staged"          => "/#{instance.instance_id}",
      }

      if request.has_key?("path")
        host = bootstrap.directory_server_v2.external_hostname
        uri = Dea::FileApi.generate_file_url(instance.instance_id, request["path"])

        response["file_uri_v2"] = "http://#{host}#{uri}"
      end

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

      if request["include_stats"] && instance.running?
        response["stats"] = {
          "name"       => instance.application_name,
          "uris"       => instance.application_uris,
          "host"       => bootstrap.local_ip,
          "port"       => instance.instance_host_port,
          "uptime"     => (Time.now - instance.state_starting_timestamp).to_i,
          "mem_quota"  => instance.memory_limit_in_bytes,
          "disk_quota" => instance.disk_limit_in_bytes,
          "fds_quota"  => instance.file_descriptor_limit,
          "usage"      => {
            "time" => Time.now.to_s,
            "cpu"  => instance.computed_pcpu,
            "mem"  => instance.used_memory_in_bytes / 1024,
            "disk" => instance.used_disk_in_bytes,
          },
          # Purposefully omitted, as I'm not sure what purpose it serves.
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
        "available_memory" => bootstrap.resource_manager.resources["memory"].remain,
        "prod"     => bootstrap.config.only_production_apps?,
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

      used_memory = bootstrap.instance_registry.inject(0) do |a, i|
        a + (i.used_memory_in_bytes / (1024 * 1024))
      end

      rm = bootstrap.resource_manager

      extra = {
        "max_memory"      => rm.resources["memory"].capacity,
        "reserved_memory" => rm.resources["memory"].used,
        "used_memory"     => used_memory,
        "num_clients"     => rm.resources["num_instances"].used,
      }

      hello.merge(extra)
    end
  end

  class ExitMessage
    def self.generate(instance, reason)
      msg = {
        "cc_partition" => instance.cc_partition,
        "droplet"      => instance.application_id,
        "version"      => instance.application_version,
        "instance"     => instance.instance_id,
        "index"        => instance.instance_index,
        "reason"       => reason,
      }

      if instance.crashed?
        msg["crash_timestamp"] = instance.state_timestamp.to_i
      end

      msg
    end
  end
end
