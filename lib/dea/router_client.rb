# coding: UTF-8

module Dea
  class RouterClient

    attr_reader :bootstrap

    def initialize(bootstrap)
      @bootstrap = bootstrap
    end

    def register_file_server(opts)
      req = generate_file_server_request(opts)
      bootstrap.nats.publish("router.register", req)
    end

    def unregister_file_server(opts)
      req = generate_file_server_request(opts)
      bootstrap.nats.publish("router.unregister", req)
    end

    def register_instance(instance, opts = {})
      req = generate_instance_request(instance, opts)
      bootstrap.nats.publish("router.register", req)
    end

    def unregister_instance(instance, opts = {})
      req = generate_instance_request(instance, opts)
      bootstrap.nats.publish("router.unregister", req)
    end

    private

    # Same format is used for both registration and unregistration
    def generate_instance_request(instance, opts = {})
      { "dea"  => bootstrap.uuid,
        "app"  => instance.application_id,
        "uris" => opts[:uris] || instance.application_uris,
        "host" => bootstrap.local_ip,
        "port" => instance.instance_host_port,
        "tags" => {
          "framework" => instance.framework_name,
          "runtime"   => instance.runtime_name,
        }
      }
    end

    # Same format is used for both registration and unregistration
    def generate_file_server_request(opts)
      { "host" => opts[:host],
        "port" => opts[:port],
        "uris" => [opts[:uri]],
      }
    end
  end
end
