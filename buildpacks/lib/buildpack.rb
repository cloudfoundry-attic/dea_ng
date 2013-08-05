require "timeout"
require "pathname"
require "installer"
require "rails_support"
require "procfile"

module Buildpacks
  class Buildpack
    include RailsSupport

    attr_accessor :source_directory, :destination_directory, :staging_info_path, :environment_json
    attr_reader :procfile, :environment, :app_dir, :log_dir, :tmp_dir, :cache_dir, :buildpacks_path, :staging_timeout, :staging_info_name

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
      fail "Invalid arguments for staging: #{args.inspect}"
    end

    def self.from_file(file_path)
      config = YAML.load_file(file_path)
      validate_arguments!(config["source_dir"], config["dest_dir"], config["environment"])
      new(config)
    end

    def initialize(config = {})
      @environment = config["environment"]
      @staging_info_name = config["staging_info_name"]
      @cache_dir = config["cache_dir"]

      @staging_timeout = ENV.fetch("STAGING_TIMEOUT", "900").to_i

      @source_directory = File.expand_path(config["source_dir"])
      @destination_directory = File.expand_path(config["dest_dir"])
      @app_dir = File.join(destination_directory, "app")
      @log_dir = File.join(destination_directory, "logs")
      @tmp_dir = File.join(destination_directory, "tmp")
      @cache_dir ||= "/tmp/cache"
      @buildpacks_path = Pathname.new(__FILE__) + '../../vendor/'

      @procfile = Procfile.new("#{app_dir}/Procfile")
    end

    def stage_application
      Dir.chdir(destination_directory) do
        create_app_directories
        copy_source_files

        compile_with_timeout(staging_timeout)

        stage_rails_console if rails_buildpack?(build_pack)
        save_buildpack_info
      end
    end

    def create_app_directories
      FileUtils.mkdir_p(app_dir)
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(tmp_dir)
    end

    def copy_source_files
      system "cp -a #{File.join(source_directory, ".")} #{app_dir}"
      FileUtils.chmod_R(0744, app_dir)
    end

    def compile_with_timeout(timeout)
      Timeout.timeout(timeout) do
        build_pack.compile
      end
    end

    def save_buildpack_info
      buildpack_info = {
        "detected_buildpack"  => build_pack.name,
        "start_command" => start_command # TODO: change to just release info; calculate start command at runtime not compile time
      }

      File.open(File.join(destination_directory, staging_info_name), 'w') do |f|
        YAML.dump(buildpack_info, f)
      end
    end

    def build_pack
      @build_pack ||= begin
        custom_buildpack_url = environment["buildpack"]
        if custom_buildpack_url
          clone_buildpack(custom_buildpack_url)
        else
          build_pack = installers.detect(&:detect)
          raise "Unable to detect a supported application type" unless build_pack
          build_pack
        end
      end
    end

    private

    def release_info
      build_pack.release_info
    end

    def installers
      buildpacks_path.children.map do |buildpack|
        Buildpacks::Installer.new(buildpack, app_dir, cache_dir)
      end
    end

    def clone_buildpack(buildpack_url)
      buildpack_path = "/tmp/buildpacks/#{File.basename(buildpack_url)}"
      ok = system("git clone --recursive #{buildpack_url} #{buildpack_path}")
      raise "Failed to git clone buildpack" unless ok
      Buildpacks::Installer.new(Pathname.new(buildpack_path), app_dir, cache_dir)
    end

    def start_command
      return environment["meta"]["command"] if environment["meta"] && environment["meta"]["command"]
      procfile.web ||
        release_info.fetch("default_process_types", {})["web"] ||
        raise("Please specify a web start command in your manifest.yml or Procfile")
    end
  end
end
