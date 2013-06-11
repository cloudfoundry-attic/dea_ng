require "timeout"
require "pathname"
require "staging_plugin"
require "installer"
require "rails_support"

module Buildpacks
  class Buildpack < StagingPlugin
    include RailsSupport

    def stage_application
      Dir.chdir(destination_directory) do
        create_app_directories
        copy_source_files

        compile_with_timeout(staging_timeout)

        stage_rails_console if rails_buildpack?
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

      custom_url = environment["buildpack"]
      return @build_pack = clone_buildpack(custom_url) if custom_url

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
      procfile["web"] ||
        release_info.fetch("default_process_types", {})["web"] ||
          raise("Please specify a web start command in your manifest.yml or Procfile")
    end

    def procfile
      @procfile ||= procfile_contents ? YAML.load(procfile_contents) : {}
      raise "Invalid Procfile format.  Please ensure it is a valid YAML hash" unless @procfile.kind_of?(Hash)
      @procfile
    end

    def procfile_contents
      procfile_path = "#{app_dir}/Procfile"

      File.read(procfile_path) if File.exists?(procfile_path)
    end

    # TODO - remove this when we have the ability to ssh to a locally-running console
    def rails_buildpack?
      @build_pack.name == "Ruby/Rails"
    end

    def startup_script
      generate_startup_script(environment_variables) do
        script_content = <<-BASH
unset GEM_PATH
if [ -d app/.profile.d ]; then
  for i in app/.profile.d/*.sh; do
    if [ -r $i ]; then
      . $i
    fi
  done
  unset i
fi
env > logs/env.log
BASH
        script_content += console_start_script if rails_buildpack?
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

    def environment_variables
      vars = release_info['config_vars'] || {}
      vars.each { |k, v| vars[k] = "${#{k}:-#{v}}" }
      vars["HOME"] = "$PWD/app"
      vars["PORT"] = "$VCAP_APP_PORT"
      vars["DATABASE_URL"] = database_uri if rails_buildpack? && bound_database_uri
      vars["MEMORY_LIMIT"] = "#{application_memory}m"
      vars
    end

    def staging_timeout
      ENV.fetch("STAGING_TIMEOUT", "900").to_i
    end
  end
end
