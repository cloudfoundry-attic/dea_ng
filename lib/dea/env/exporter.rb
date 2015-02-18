module Dea
  class Env
    class Exporter < Struct.new(:variables)
      def export
        variables.map do |(key, value)|
          key = key.to_s
          value = value.to_s
          if key == "DATABASE_URL" || key == "VCAP_SERVICES" || key == "VCAP_APPLICATION"
            %Q{export %s=%s;\n} % [key, Shellwords.shellescape(value)]
          else
            %Q{export %s="%s";\n} % [key, value.gsub('"', '\"')]
          end
        end.join
      end
    end
  end
end
