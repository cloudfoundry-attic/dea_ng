require "yaml"
require "fileutils"

module LanguagePack
  class CBase

    DEFAULT_RELEASE_INFO_FILE = "Release".freeze
    
    
    attr_reader :build_path, :cache_path

    def initialize(build_path, cache_path=nil)
      @build_path = build_path
      @cache_path = cache_path
    end

    def compile
      Dir.chdir(build_path) do
        create_manifest
        create_main_script
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
    
    def addons
      release_info["addons"]||[]
    end
    
    def config_vars
      release_info["config_vars"]||{}
    end

    def default_process_types
      {"web"=>"./_main.sh"}
    end

    def setup_profiled
      FileUtils.mkdir_p "#{build_path}/.profile.d"
    end

    def release_file
      File.join(build_path,DEFAULT_RELEASE_INFO_FILE)
    end

    def release_info
      @release_info ||= File.exists?(release_file) ? YAML.load_file(release_file) : {}
        raise "#{DEFAULT_RELEASE_INFO_FILE}: invalid yaml format" unless @release_info.kind_of?(Hash)
      @release_info
    end

    def main_script
      script=<<-BASH
#!/bin/bash      
function timeout(){
  to_time=${1}
  shift
  (eval $@) &
  process_pid=$!
  (sleep "${to_time}";  kill "${process_pid}") 2>/dev/null &
  killer_pid=$!
  wait "${process_pid}" 2>/dev/null
  ret=$?
  kill -HUP "${killer_pid}" 2>/dev/null
  return "${ret}"
}
  (./#{control_script} start) &
timeout #{start_timeout} "until ./#{control_script} start_check; do sleep 1;done"
while :; do timeout #{status_timeout} ./#{control_script} status || exit $?; sleep 1;done
BASH
    end

    def control_script
      release_info["control_script"] || "control.sh"
    end

    def status_timeout
      release_info["status_timeout"] || 5
    end

    def start_timeout
      release_info["start_timeout"] || 20
    end

    def status_file
      release_info["status_file"] ? "#{release_info["status_file"]}":"status.file"
    end

  
    def create_main_script
      path = File.join(build_path, '_main.sh')
        File.open(path, 'wb') do |f|
          f.puts main_script
        end
      FileUtils.chmod(0544, path)
    end

    def create_manifest
      droplet={ 
        "state_file" => "status_file"
      }
      #droplet=droplet.merge(release_info.fetch("ports")) if release_info.key?("ports")
      droplet["state_file"] = status_file
      droplet["start_timeout"] = start_timeout
      droplet["raw_ports"] = release_info["ports"] if release_info.key?("ports")
      File.open('../droplet.yaml', 'w') { |f| YAML.dump(droplet, f) }
    end

  end
end
