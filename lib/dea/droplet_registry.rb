require "dea/droplet"
require "steno"

module Dea
  class DropletRegistry < Hash
    attr_reader :base_path

    def initialize(base_path)
      super() do |hash, sha1|
        logger.debug "new droplet", :sha1 => sha1

        hash[sha1] = Droplet.new(base_path, sha1)
      end

      # Seed registry with available droplets
      Dir[File.join(base_path, "*")].each do |path|
        self[File.basename(path)]
      end

      @base_path = base_path
    end

    private

    def logger
      @logger ||= Steno.logger(self.class.name)
    end
  end
end
