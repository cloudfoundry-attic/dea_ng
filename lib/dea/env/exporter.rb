require 'shellwords'

module Dea
  class Env
    class Exporter < Struct.new(:variables)
      def export
        variables.map do |(key, value)|
          %Q{export %s=%s;\n} % [key, Shellwords.shellescape(value.to_s)]
        end.join
      end
    end
  end
end