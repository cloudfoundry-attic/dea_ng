# coding: UTF-8

require "membrane"

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
        }
      end
    end
  end
end
