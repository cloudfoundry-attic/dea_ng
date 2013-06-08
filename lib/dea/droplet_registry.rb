# coding: UTF-8

require "dea/droplet"
require "steno"
require "steno/core_ext"

module Dea
  class DropletRegistry < Hash
    attr_reader :base_dir

    def initialize(base_dir)
      super() do |hash, sha1|
        logger.debug "droplet-registry.droplet.new", :sha1 => sha1

        hash[sha1] = Droplet.new(base_dir, sha1)
      end

      # Seed registry with available droplets
      Dir[File.join(base_dir, "*")].each do |path|
        self[File.basename(path)]
      end

      @base_dir = base_dir
    end

    private

    def logger
      @logger ||= self.class.logger
    end
  end
end
