module Dea
  class DatabaseUriGenerator
    VALID_DB_TYPES = %w[mysql mysql2 postgres postgresql].freeze
    DATABASE_TO_ADAPTER_MAPPING = {
      'mysql' => 'mysql2',
      'mysql2' => 'mysql2',
      'postgres' => 'postgresql'
    }.freeze

    def initialize(services)
      @services = services || []
    end

    def database_uri
      convert_scheme_to_rails_adapter(bound_database_uri).to_s if bound_database_uri
    end

    private

    def bound_database_uri
      case bound_relational_valid_databases.size
        when 0
          nil
        when 1
          bound_relational_valid_databases.first[:uri]
        else
          binding = bound_relational_valid_databases.detect { |binding| binding[:name] && binding[:name] =~ /^.*production$|^.*prod$/ }
          unless binding
            raise "Unable to determine primary database from multiple. Please bind only one database service to Rails applications."
          end
          binding[:uri]
      end
    end

    def bound_relational_valid_databases
      @bound_relational_valid_databases ||= @services.inject([]) do |collection, binding|
        begin
          if binding["credentials"]["uri"]
            uri = URI.parse(binding["credentials"]["uri"])
            collection << {uri: uri, name: binding["name"]} if VALID_DB_TYPES.include?(uri.scheme)
          end
        rescue URI::InvalidURIError => e
          raise URI::InvalidURIError, "Invalid database uri: #{binding["credentials"]["uri"].gsub(/\/\/.+@/, '//USER_NAME_PASS@')}"
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