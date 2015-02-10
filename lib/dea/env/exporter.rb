module Dea
  class Env
    class Exporter < Struct.new(:variables)
      def export
        variables.map do |(key, value)|
          if key == "VCAP_SERVICES" || key == "VCAP_APPLICATION"
            value = value.to_s.gsub('$', '\$')
            %Q{export %s=%s;\n} % [key, Shellwords.shellescape(value)]
          else
            %Q{export %s="%s";\n} % [key, value.to_s.gsub('"', '\"')]
          end
        end.join
      end
    end
  end
end
