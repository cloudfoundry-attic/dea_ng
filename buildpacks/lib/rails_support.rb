require "yaml"
require "fileutils"
require "securerandom"
require "uri"

module Buildpacks
  module RailsSupport
    VALID_DB_TYPES = %w[mysql mysql2 postgres postgresql].freeze
    DATABASE_TO_ADAPTER_MAPPING = {
      'mysql' => 'mysql2',
      'mysql2' => 'mysql2',
      'postgres' => 'postgresql'
    }.freeze

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

    def database_uri
      convert_scheme_to_rails_adapter(bound_database_uri).to_s
    end

    def bound_database_uri
      case bound_relational_databases.size
        when 0
          nil
        when 1
          bound_relational_databases.first.first
        else
          binding = bound_relational_databases.detect { |_, name| name && name =~ /^.*production$|^.*prod$/ }
          unless binding
            raise "Unable to determine primary database from multiple. " +
              "Please bind only one database service to Rails applications."
          end
          binding.first
      end
    end

    private

    def bound_relational_databases
      @bound_services ||= bound_services.inject([]) do |collection, binding|
        begin
          if binding["credentials"]["uri"]
            uri = URI.parse(binding["credentials"]["uri"])
            if VALID_DB_TYPES.include?(uri.scheme)
              collection << [uri, binding["name"]]
            end
          end
        rescue URI::InvalidURIError => e
          raise "Invalid database uri: #{binding["credentials"]["uri"].gsub(/\/\/.+@/, '//USER_NAME_PASS@')}"
        end
        collection
      end
    end

    def convert_scheme_to_rails_adapter(uri)
      uri.scheme = DATABASE_TO_ADAPTER_MAPPING[uri.scheme] if DATABASE_TO_ADAPTER_MAPPING[uri.scheme]
      uri
    end
  end
end
