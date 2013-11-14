require "dea/starting/startup_script_generator"

module Dea
  class WinStartupScriptGenerator < StartupScriptGenerator
    WIN_START_SCRIPT = strip_heredoc(<<-BASH).freeze
        $droplet_base_dir = $PWD
        $stdout_path = "$droplet_base_dir\\logs\\stdout.log"
        $stderr_path = "$droplet_base_dir\\logs\\stderr.log"
        cd app
        $process = Start-Process -FilePath %s -NoNewWindow -PassThru -RedirectStandardOutput $stdout_path -RedirectStandardError $stderr_path -ArgumentList "-p $port"
        Set-Content -Path "$droplet_base_dir\\run.pid" -Encoding ASCII $process.id
        Wait-Process -InputObject $process
    BASH

    def generate
      script = []
      script << @system_envs
      script << @user_envs
      script << WIN_START_SCRIPT % @start_command
      script.join("\n")
    end
  end
end