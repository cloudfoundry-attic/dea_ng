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
      bound_database_uri
    end

    private

    def bound_database_uri
      if bound_relational_valid_databases.any?
        bound_relational_valid_databases.first
      else
        nil
      end
    end

    def bound_relational_valid_databases
      @bound_relational_valid_databases ||= @services.inject([]) do |collection, binding|
        credentials = binding["credentials"]
        if credentials && credentials["uri"]
          (scheme, rest) = binding["credentials"]["uri"].split(":", 2)
          if scheme && rest
            collection << "#{convert_scheme_to_rails_style_adapter(scheme)}:#{rest}" if VALID_DB_TYPES.include?(scheme)
          end
        end
        collection
      end
    end

    def convert_scheme_to_rails_style_adapter(scheme)
      return RAILS_STYLE_DATABASE_TO_ADAPTER_MAPPING[scheme] if RAILS_STYLE_DATABASE_TO_ADAPTER_MAPPING[scheme]
      scheme
    end
  end
end
