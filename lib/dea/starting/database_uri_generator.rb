module Dea
  class DatabaseUriGenerator
    VALID_DB_TYPES = %w[mysql mysql2 postgres postgresql db2 informix].freeze
    RAILS_STYLE_DATABASE_TO_ADAPTER_MAPPING = {
      'mysql' => 'mysql2',
      'postgresql' => 'postgres',
      'db2' => 'ibmdb',
      'informix' => 'ibmdb'
    }.freeze

    def initialize(services)
      @services = Array(services).compact || []
    end

    def database_uri
      convert_scheme_to_rails_style_adapter(bound_database_uri).to_s if bound_database_uri
    end

    private

    def bound_database_uri
      if bound_relational_valid_databases.any?
        bound_relational_valid_databases.first[:uri]
      else
        nil
      end
    end

    def bound_relational_valid_databases
      @bound_relational_valid_databases ||= @services.inject([]) do |collection, binding|
        begin
          credentials = binding["credentials"]
          if credentials && credentials["uri"]
            uri = URI.parse(binding["credentials"]["uri"])
            collection << {uri: uri, name: binding["name"]} if VALID_DB_TYPES.include?(uri.scheme)
          end
        rescue URI::InvalidURIError => e
        end
        collection
      end
    end

    def convert_scheme_to_rails_style_adapter(uri)
      uri.scheme = RAILS_STYLE_DATABASE_TO_ADAPTER_MAPPING[uri.scheme] if RAILS_STYLE_DATABASE_TO_ADAPTER_MAPPING[uri.scheme]
      uri
    end
  end
end
