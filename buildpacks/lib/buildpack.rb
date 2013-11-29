require "timeout"
require "pathname"
require "installer"
require "rails_support"
require "procfile"
require "services"

module Buildpacks
  class Buildpack
    include RailsSupport

    attr_accessor :source_directory, :destination_directory, :staging_info_path, :environment_json
    attr_reader :procfile, :environment

    def self.platform_config
      YAML.load_file(ENV['PLATFORM_CONFIG'])
    end

    def self.validate_arguments!(*args)
      source, dest, env = args
      argfail!(args) unless source && dest && env
      argfail!(args) unless File.directory?(File.expand_path(source))
      argfail!(args) unless File.directory?(File.expand_path(dest))
    end

    def self.argfail!(args)
      puts "Invalid arguments for staging: #{args.inspect}"
      exit 1
    end

    def self.from_file(file_path)
      config = YAML.load_file(file_path)
      validate_arguments!(config["source_dir"], config["dest_dir"], config["environment"])
      new(config)
    end

    def initialize(config = {})
      @source_directory = File.expand_path(config["source_dir"])
      @destination_directory = File.expand_path(config["dest_dir"])
      @environment = config["environment"]
      @staging_info_path = config["staging_info_path"]
      @cache_dir = config["cache_dir"]
      @procfile = Procfile.new("#{app_dir}/Procfile")
      @services = Services.new(@environment["services"])
    end

    def app_dir
      File.join(destination_directory, "app")
    end

    def log_dir
      File.join(destination_directory, "logs")
    end

    def tmp_dir
      File.join(destination_directory, "tmp")
    end

    def cache_dir
      @cache_dir || "/tmp/cache"
    end

    def script_dir
      destination_directory
    end

    def application_memory
      if environment["resources"] && environment["resources"]["memory"]
        environment["resources"]["memory"]
      else
        512 #MB
      end
    end

    def generate_startup_script(env_vars = {})
      after_env_before_script = block_given? ? yield : "\n"
      <<-SCRIPT.gsub(/^\s{8}/, "")
        #!/bin/bash
        #{environment_statements_for(env_vars)}
      #{after_env_before_script}
        DROPLET_BASE_DIR=$PWD
        (#{start_command}) > $DROPLET_BASE_DIR/logs/stdout.log 2> $DROPLET_BASE_DIR/logs/stderr.log &
        STARTED=$!
        echo "$STARTED" >> $DROPLET_BASE_DIR/run.pid
        wait $STARTED
      SCRIPT
    end

    # Generates newline-separated exports for the specified environment variables.
    # If the value of one of the keys is false or nil, it will be an 'unset' instead of an 'export'
    def environment_statements_for(vars)
      # Passed vars should overwrite common vars
      common_env_vars = { "TMPDIR" => tmp_dir.gsub(destination_directory,"$PWD") }
      vars = common_env_vars.merge(vars)
      lines = []
      vars.each do |name, value|
        if value
          lines << "export #{name}=\"#{value}\""
        else
          lines << "unset #{name}"
        end
      end
      lines.sort.join("\n")
    end

    def create_app_directories
      FileUtils.mkdir_p(app_dir)
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(tmp_dir)
    end

    def create_startup_script
      path = File.join(script_dir, 'startup')
      File.open(path, 'wb') do |f|
        f.puts startup_script
      end
      FileUtils.chmod(0544, path)
    end

    def copy_source_files(dest=nil)
      system "cp -a #{File.join(source_directory, ".")} #{dest || app_dir}"
      FileUtils.chmod_R(0755, app_dir)
    end

    def stage_application
      Dir.chdir(destination_directory) do
        create_app_directories
        copy_source_files

        compile_with_timeout(staging_timeout)

        stage_rails_console if rails_buildpack?(build_pack)
        create_startup_script
        save_buildpack_info
      end
    end

    def compile_with_timeout(timeout)
      Timeout.timeout(timeout) do
        build_pack.compile
      end
    end

    def clone_buildpack(buildpack_url)
      buildpack_path = "/tmp/buildpacks/#{File.basename(buildpack_url)}"
      ok = system("git clone --recursive #{buildpack_url} #{buildpack_path}")
      raise "Failed to git clone buildpack" unless ok
      Buildpacks::Installer.new(Pathname.new(buildpack_path), app_dir, cache_dir)
    end

    def build_pack
      return @build_pack if @build_pack

      custom_buildpack_url = environment["buildpack"]
      return @build_pack = clone_buildpack(custom_buildpack_url) if custom_buildpack_url

      @build_pack = installers.detect(&:detect)
      raise "Unable to detect a supported application type" unless @build_pack

      @build_pack
    end

    def buildpacks_path
      Pathname.new(__FILE__) + '../../vendor/'
    end

    def installers
      buildpacks_path.children.map do |buildpack|
        Buildpacks::Installer.new(buildpack, app_dir, cache_dir)
      end
    end

    def start_command
      return environment["meta"]["command"] if environment["meta"] && environment["meta"]["command"]
      procfile.web ||
        release_info.fetch("default_process_types", {})["web"] ||
          raise("Please specify a web start command in your manifest.yml or Procfile")
    end

    def startup_script
      generate_startup_script(running_environment_variables) do
        script_content = <<-BASH
unset GEM_PATH
if [ -d .profile.d ]; then
  for i in .profile.d/*.sh; do
    if [ -r $i ]; then
      . $i
    fi
  done
  unset i
fi
env > logs/env.log
BASH
        script_content += console_start_script if rails_buildpack?(build_pack)
        script_content
      end
    end

    def release_info
      build_pack.release_info
    end

    def save_buildpack_info
      buildpack_info = {
        "detected_buildpack"  => @build_pack.name
      }

      File.open(staging_info_path, 'w') { |f| YAML.dump(buildpack_info, f) }
    end

    def running_environment_variables
      vars = release_info['config_vars'] || {}
      vars.each { |k, v| vars[k] = "${#{k}:-#{v}}" }
      vars["HOME"] = "$PWD"
      vars["PORT"] = "$VCAP_APP_PORT"
      vars["DATABASE_URL"] = @services.database_uri if rails_buildpack?(build_pack) && @services.database_uri
      vars["MEMORY_LIMIT"] = "#{application_memory}m"
      vars
    end

    def staging_timeout
      ENV.fetch("STAGING_TIMEOUT", "900").to_i
    end
  end
end
