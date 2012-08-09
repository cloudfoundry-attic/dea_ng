# coding: UTF-8

require "membrane"

require "dea/runtime"

module Dea
  class Config
    EMPTY_CONFIG = {
      "intervals" => {},
      "status"    => {},
      "resources" => {},
    }

    def self.schema
      ::Membrane::SchemaParser.parse do
        {
          "base_dir" => String,
          optional("local_route") => String,
          "logging" => {
            "level"            => String,
            optional("file")   => String,
            optional("syslog") => String,
          },
          "nats_uri" => String,
          "pid_filename" => String,
          "runtimes" => dict(String, Dea::Runtime.schema),
          "warden_socket" => String,
          "index" => Integer,

          "directory_server_port" => Integer,

          optional("status") => {
            "user"     => String,
            "port"     => Integer,
            "password" => String,
          },

          optional("intervals") => {
            optional("heartbeat") => Integer,
            optional("advertise") => Integer,
          },

          optional("resources") => {
            optional("memory_mb") => Integer,
            optional("memory_overcommit_factor") => enum(Float, Integer),

            optional("disk_mb") => Integer,
            optional("disk_overcommit_factor") => enum(Float, Integer),

            optional("num_instances") => Integer,
          },
        }
      end
    end
  end
end
