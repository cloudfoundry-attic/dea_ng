module Dea
  class EnvExporter < Struct.new(:variables)
    def export
      variables.map do |(key, value)|
        %Q{export %s="%s";\n} % [key, value.to_s.gsub('"', '\"')]
      end.join
    end
  end
end