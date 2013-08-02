require "yaml"
require "fileutils"
require "securerandom"
require "uri"

module Buildpacks
  module RailsSupport
    def stage_rails_console
      # Copy cf-rails-console to app
      cf_rails_console_dir = app_dir + '/cf-rails-console'
      FileUtils.mkdir_p(cf_rails_console_dir)
      FileUtils.cp_r(File.expand_path('../resources/cf-rails-console', __FILE__), app_dir)

      # Generate console access file for caldecott access
      config_file = cf_rails_console_dir + '/.consoleaccess'
      data = {'username' => SecureRandom.hex, 'password' => SecureRandom.hex}

      File.open(config_file, 'w') do |fh|
        fh.write(YAML.dump(data))
      end
    end

    # TODO - remove this when we have the ability to ssh to a locally-running console
    def rails_buildpack?(buildpack)
      buildpack.name == "Ruby/Rails"
    end
  end
end
