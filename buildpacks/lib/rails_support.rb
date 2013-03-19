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
    # Prepares a database.yml file for the app, if needed.
    # Returns the service binding that was used for the 'production' db entry.
    def configure_database
      write_database_yaml if bound_database
    end

    def database_uri
      "#{database_type}://#{credentials['username']}:#{credentials['password']}@#{credentials['host']}:#{credentials['port']}/#{credentials['database']}"
    end

    # Actually lay down a database.yml in the app's config directory.
    def write_database_yaml
      data = database_config
      conf = File.join(destination_directory, 'app', 'config', 'database.yml')
      settings = File.exists?(conf) ? YAML.load_file(conf) : {}
      settings['production']=data
      File.open(conf, 'w') do |fh|
        YAML.dump(settings, fh)
      end
      binding
    end

    def bound_database
      case bound_databases.size
        when 0
          nil
        when 1
          bound_databases.first
        else
          binding = bound_databases.detect { |b| b["name"] && b["name"] =~ /^.*production$|^.*prod$/ }
          if !binding
            raise "Unable to determine primary database from multiple. " +
              "Please bind only one database service to Rails applications."
          end
          binding
      end
    end

    def database_type
      case bound_database["label"]
        when /^mysql/
          "mysql2"
        when /^postgres/
          "postgres"
        else
          raise "Unable to configure unknown database: #{binding.inspect}"
      end
    end

    DATABASE_TO_ADAPTER_MAPPING = {
      :mysql => 'mysql2',
      :mysql2 => 'mysql2',
      :postgres => 'postgresql'
    }


    def database_config
      {
        'adapter' =>  DATABASE_TO_ADAPTER_MAPPING.fetch(database_type),
        'encoding' => 'utf8',
        'pool' => 5,
        'reconnect' => false
      }.merge(credentials)
    end

    # return host, port, username, password, and database
    def credentials
      creds = bound_database["credentials"]
      unless creds
        raise "Database binding failed to include credentials"
      end
      {
        'host' => creds["hostname"],
        'port' => creds["port"],
        'username' => creds["user"],
        'password' => creds["password"],
        'database' => creds["name"]
      }
    end

    def bound_databases
      @bound_services ||= bound_services.select { |binding| known_database?(binding) }
    end

    def known_database?(binding)
      if label = binding["label"]
        case label
          when /^mysql/
            binding
          when /^postgresql/
            binding
        end
      end
    end
  end
end
