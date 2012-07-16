require "dea/droplet"

module Dea
  class DropletRegistry < Hash
    attr_reader :base_path

    def initialize(base_path)
      super() do |hash, sha1|
        hash[sha1] = Droplet.new(base_path, sha1)
      end

      # Seed registry with available droplets
      Dir[File.join(base_path, "*")].each do |path|
        self[File.basename(path)]
      end

      @base_path = base_path
    end
  end
end
