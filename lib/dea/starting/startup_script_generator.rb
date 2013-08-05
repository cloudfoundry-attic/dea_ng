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

    RAILS_CONSOLE_SCRIPT = strip_heredoc(<<-BASH).freeze
      pushd app
        bundle exec ruby cf-rails-console/rails_console.rb >> ../logs/console.log 2>> ../logs/console.log &
        CONSOLE_STARTED=$!
        echo "$CONSOLE_STARTED" >> ../console.pid
      popd
    BASH

    START_SCRIPT = strip_heredoc(<<-BASH).freeze
      DROPLET_BASE_DIR=$PWD
      cd app
      (%s) > >(tee $DROPLET_BASE_DIR/logs/stdout.log) 2> >(tee $DROPLET_BASE_DIR/logs/stderr.log >&2) &
      STARTED=$!
      echo "$STARTED" >> $DROPLET_BASE_DIR/run.pid

      wait $STARTED
    BASH

    def initialize(start_command, user_envs, system_envs, used_buildpack)
      @start_command = start_command
      @user_envs = user_envs
      @system_envs = system_envs
      @used_buildpack = used_buildpack
    end

    def generate
      script = []
      script << "umask 077"
      script << @system_envs
      script << EXPORT_BUILDPACK_ENV_VARIABLES_SCRIPT
      script << @user_envs
      script << "env > logs/env.log"
      script << RAILS_CONSOLE_SCRIPT if @used_buildpack == "Ruby/Rails"
      script << START_SCRIPT % @start_command
      script.join("\n")
    end
  end
end