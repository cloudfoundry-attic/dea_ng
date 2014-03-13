require "yaml"
require "fileutils"
require "timeout"
require "pathname"
require "installer"
require "procfile"
require "git"
require "platform_detect"

module Buildpacks
  class Buildpack
    attr_accessor :source_directory, :destination_directory, :staging_info_path, :environment_json
    attr_reader :procfile, :environment, :app_dir, :log_dir, :tmp_dir, :cache_dir, :buildpack_dirs, :staging_timeout, :staging_info_name

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
      @buildpack_dirs = config.fetch("buildpack_dirs")

      @procfile = Procfile.new("#{app_dir}/Procfile")
    end

    def stage_application
      Dir.chdir(destination_directory) do
        create_app_directories
        copy_source_files

        compile_with_timeout(staging_timeout)

        save_buildpack_info
      end
    end

    def create_app_directories
      FileUtils.mkdir_p(app_dir)
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(tmp_dir)
    end

    def copy_source_files
      cp_a(File.join(source_directory, "."), app_dir)
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
        "start_command" => start_command
      }

      File.open(File.join(destination_directory, staging_info_name), 'w') do |f|
        YAML.dump(buildpack_info, f)
      end
    end

    def build_pack
      @build_pack ||= begin
        if custom_buildpack_url
          clone_buildpack(custom_buildpack_url)
        elsif specified_buildpack_key
          buildpack_with_key(specified_buildpack_key)
        else
          detected_buildpack = installers.find(&:detect)
          raise "Unable to detect a supported application type" unless detected_buildpack
          detected_buildpack
        end
      end
    end

    private

    def release_info
      build_pack.release_info
    end

    def installers
      @installers ||= buildpack_dirs.map do |buildpack|
        Buildpacks::Installer.new(buildpack, app_dir, cache_dir)
      end
    end

    def custom_buildpack_url
      environment["buildpack"] || environment["buildpack_git_url"]
    end

    def specified_buildpack_key
      environment["buildpack_key"]
    end

    def clone_buildpack(buildpack_url)
      buildpack_path = Git.clone(buildpack_url, '/tmp/buildpacks')
      Buildpacks::Installer.new(Pathname.new(buildpack_path), app_dir, cache_dir)
    end

    def buildpack_with_key(buildpack_key)
      detected_buildpack_dir = buildpack_dirs.find do |dir|
        File.basename(dir) == specified_buildpack_key
      end
      Buildpacks::Installer.new(detected_buildpack_dir, app_dir, cache_dir)
    end

    def start_command
      # remain compatible with components sending a command as part of staging
      if environment["meta"] && environment["meta"]["command"]
        return environment["meta"]["command"]
      end

      procfile.web || release_info.fetch("default_process_types", {})["web"]
    end

    def cp_a(src, dest)
      if PlatformDetect.windows?
        FileUtils.cp_r(src, dest, :preserve => true)
      else
        # recursively (-r) while not following symlinks (-P) and preserving dir structure (-p)
        # this is why we use system copy not FileUtil
        system "cp -a #{src} #{dest}"
      end
    end
  end
end
