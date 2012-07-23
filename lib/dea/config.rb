# coding: UTF-8

require "membrane"

require "dea/runtime"

module Dea
  class Config
    def self.schema
      ::Membrane::SchemaParser.parse do
        {
          "base_dir" => String,
          "logging" => {
            "level"            => String,
            optional("file")   => String,
            optional("syslog") => String,
          },
          "nats_uri" => String,
          "pid_filename" => String,
          "runtimes" => dict(String, Dea::Runtime.schema),
        }
      end
    end
  end
end
