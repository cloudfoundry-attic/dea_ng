require "dea/env"

module Dea
  class WinEnv < Env
    def to_export(envs)
      envs.map do |(key, value)|
        %Q{$env:%s='%s'\n} % [key, value]
      end.join
    end
  end
end