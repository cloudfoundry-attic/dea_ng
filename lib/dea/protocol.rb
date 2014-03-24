# coding: UTF-8

require "dea/version"

module Dea
  module Protocol; end
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
        "staged"          => "/#{instance.instance_id}",
      }

      if request.has_key?("path")
        response["file_uri_v2"] = bootstrap.directory_server_v2.instance_file_url_for(instance.instance_id, request["path"])
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
            "mem"  => instance.used_memory_in_bytes,
            "disk" => instance.used_disk_in_bytes,
          },
          # Purposefully omitted, as I'm not sure what purpose it serves.
          # cores
        }
      end

      response
    end
  end

  class AdvertiseMessage
    def self.generate(message={})
      { "id" => message[:id],
        "stacks" => message[:stacks],
        "available_memory" => message[:available_memory],
        "available_disk" => message[:available_disk],
        "available_instances" => message[:available_instances],
        "app_id_to_count" => message[:app_id_to_count],
        "placement_properties" => {"zone" => message[:placement_zone]},
      }
    end
  end

  class HelloMessage
    def self.generate(bootstrap)
      { "id"   => bootstrap.uuid,
        "ip"   => bootstrap.local_ip,
        "version" => Dea::VERSION,
      }
    end
  end

  class GoodbyeMessage
    def self.generate(uuid, local_ip, instance_registry)
      { "id"   => uuid,
        "ip"   => local_ip,
        "version" => Dea::VERSION,
        "app_id_to_count" => instance_registry.app_id_to_count
      }
    end
  end

  class DeaStatusResponse
    def self.generate(bootstrap)
      hello = HelloMessage.generate(bootstrap)
      rm = bootstrap.resource_manager

      hello.merge({
        "max_memory"      => rm.memory_capacity,
        "reserved_memory" => rm.reserved_memory,
        "used_memory"     => rm.used_memory,
        "num_clients"     => nil
      })
    end
  end

  class ExitMessage
    def self.generate(instance, reason)
      msg = {
        "cc_partition"     => instance.cc_partition,
        "droplet"          => instance.application_id,
        "version"          => instance.application_version,
        "instance"         => instance.instance_id,
        "index"            => instance.instance_index,
        "reason"           => reason,
        "exit_status"      => instance.exit_status,
        "exit_description" => instance.exit_description,
      }

      if instance.crashed?
        msg["crash_timestamp"] = instance.state_timestamp.to_i
      end

      msg
    end
  end
end
