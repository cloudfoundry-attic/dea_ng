module Dea
  class StartupScriptGenerator
    def self.strip_heredoc(string)
      indent = string.scan(/^[ \t]*(?=\S)/).min.try(:size) || 0
      string.gsub(/^[ \t]{#{indent}}/, '')
    end

    EXPORT_BUILDPACK_ENV_VARIABLES_SCRIPT = strip_heredoc(<<-BASH).freeze
      unset GEM_PATH
      if [ -d app/.profile.d ]; then
        for i in app/.profile.d/*.sh; do
          if [ -r $i ]; then
            . $i
          fi
        done
        unset i
      fi
    BASH

    START_SCRIPT = strip_heredoc(<<-BASH).freeze
      DROPLET_BASE_DIR=$PWD
      cd app
      (%s) &
      STARTED=$!
      echo "$STARTED" >> $DROPLET_BASE_DIR/run.pid

      wait $STARTED
    BASH

    def initialize(start_command, user_envs, system_envs, log_env)
      @start_command = start_command
      @user_envs = user_envs
      @system_envs = system_envs
      @log_env = log_env
    end

    def generate
      script = []
      script << "umask 077"
      script << @system_envs
      script << EXPORT_BUILDPACK_ENV_VARIABLES_SCRIPT
      script << @user_envs
      if @log_env
        script << "env > logs/env.log"
      end
      script << START_SCRIPT % @start_command
      script.join("\n")
    end
  end
end