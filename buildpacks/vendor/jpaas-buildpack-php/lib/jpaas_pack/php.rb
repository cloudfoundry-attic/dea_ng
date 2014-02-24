require "jpaas_pack/release"

require "yaml"
require "fileutils"

module JpaasPack
  class Php

    include JpaasPack::Release

    attr_reader :build_path, :cache_path

    # @param [String] the path of the build dir
    # @param [String] the path of the cache dir
    def initialize(build_path, cache_path=nil)
      @build_path = build_path
      @cache_path = cache_path
    end

    # changes directory to the build_path
    def compile
      Dir.chdir(build_path) do
        do_compile
      end
    end

    def do_compile
      raise NotImplementedError, "subclasses must implement a 'do_compile' method"
    end

    def release
      {
          "addons" => addons,
          "config_vars" => config_vars,
          "default_process_types" => default_process_types
      }.to_yaml
    end

    def  addons
      release_info["addons"]||[]
    end

    def config_vars
      release_info["config_vars"]||{}
    end

    def default_process_types
      release_info["default_process_types"]||{"web"=>"./jpaas_control start"}
    end

    # run a shell comannd and pipe stderr to stdout
    # @param [String] command to be run
    # @return [String] output of stdout and stderr
    def run_with_err_output(command)
      %x{ #{command} 2>&1 }
    end

    def create_droplet_yaml
      droplet_file = File.join(build_path,"../droplet.yaml")
      File.open(droplet_file, 'w') { |f| YAML.dump(droplet_info, f) }
    end

    def droplet_info
      droplet = {}
      droplet["raw_ports"] = release_info["ports"] if release_info.key?("ports")
      droplet["state_file"] = release_info["state_file"] if release_info.key?("state_file")
      droplet
    end

  end
end
