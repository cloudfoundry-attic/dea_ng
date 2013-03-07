require "yaml"
require "fileutils"
require "securerandom"

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

    def console_start_script
      <<-BASH
if [ -n "$VCAP_CONSOLE_PORT" ]; then
  cd app
  bundle exec ruby cf-rails-console/rails_console.rb >> ../logs/console.log 2>> ../logs/console.log &
  CONSOLE_STARTED=$!
  echo "$CONSOLE_STARTED" >> ../console.pid
  cd ..
fi
      BASH
    end
  end
end
