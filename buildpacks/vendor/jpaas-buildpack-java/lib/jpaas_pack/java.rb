require "jpaas_pack/package_fetcher"
require "jpaas_pack/release"

require "yaml"
require "fileutils"

module JpaasPack
  class Java
   
   include JpaasPack::PackageFetcher
   include JpaasPack::Release

    DEFAULT_JDK_VERSION = "1.6".freeze
    
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

    def install_java
      FileUtils.mkdir_p jdk_dir
      jdk_tarball = "#{jdk_dir}/jdk.tar.gz"

      download_jdk jdk_tarball

      puts "Unpacking JDK to #{jdk_dir}"
      tar_output = run_with_err_output "tar pxzf #{jdk_tarball} -C #{jdk_dir}"

      FileUtils.rm_rf jdk_tarball
      unless File.exists?("#{jdk_dir}/bin/java")
        puts "Unable to retrieve the JDK"
        puts tar_output
        exit 1
      end
    end

    def java_version
      release_info["jdk"] || DEFAULT_JDK_VERSION
    end
    
    def download_jdk(jdk_tarball)
      puts "Downloading JDK..."
      fetched_package = fetch_jdk_package(java_version)
      puts "Downloading JDK is done"
      FileUtils.mv fetched_package, jdk_tarball
    end

    def jdk_dir
      ".jdk"
    end

    def java_opts
      {
        "-Xmx" => "$MEMORY_LIMIT",
        "-Xms" => "$MEMORY_LIMIT",
        "-Djava.io.tmpdir=" => '\"$TMPDIR\"'

      # Temp disable due to crazy variable expansion issues in bash.
      #,
      #  "-XX:OnOutOfMemoryError=" => '\"echo oome killing pid: %p && kill -9 %p\"'
      }
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
       release_info["default_process_types"] || { "web" => "./jpaas_control start"}
    end

    # run a shell comannd and pipe stderr to stdout
    # @param [String] command to be run
    # @return [String] output of stdout and stderr
    def run_with_err_output(command)
      %x{ #{command} 2>&1 }
    end

    def setup_profiled
      FileUtils.mkdir_p "#{build_path}/.profile.d"
      File.open("#{build_path}/.profile.d/java.sh", "a") { |file| file.puts(bash_script) }
    end

    private

    def bash_script
      <<-BASH
#!/bin/bash
export JAVA_HOME="$HOME/app/#{jdk_dir}"
export PATH="$HOME/#{jdk_dir}/bin:$PATH"
export JAVA_OPTS=${JAVA_OPTS:-"#{java_opts.map{ |k, v| "#{k}#{v}" }.join(' ')}"}
      BASH
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
