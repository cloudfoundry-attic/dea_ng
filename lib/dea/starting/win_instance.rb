# coding: UTF-8

require "dea/win_env"
require "dea/starting/instance"
require "dea/starting/win_startup_script_generator"

module Dea
  class WinInstance < Instance

    def promise_setup_environment_script
      commands = [
        { :cmd => 'mkdir', :args => [ '@ROOT@/app' ] }
      ]
      commands.to_json
    end

    def promise_extract_droplet_script(droplet_path)
      commands = [
        { :cmd => 'tar', :args => [ 'x', '@ROOT@', droplet_path ] },
      ]
      commands.to_json
    end

    def promise_start_script(command)
      startup = []
      if self.instance_host_port
        startup << '$port = %d' % self.instance_host_port
      end
      env = WinEnv.new(StartMessage.new(@raw_attributes), self)
      if command
        startup << Dea::WinStartupScriptGenerator.new(
            command,
            env.exported_user_environment_variables,
            env.exported_system_environment_variables
        ).generate
      else
        startup << "./startup.ps1"
      end
      startup << "exit"

      commands = [ { :cmd => 'ps1', :args => startup } ]
      commands.to_json
    end

    def build_promise_exec_hook_script(script_path)
      script = []

      env = WinEnv.new(StartMessage.new(@raw_attributes), self)
      script << env.exported_environment_variables
      script << File.read(script_path)
      script << "exit"

      commands = [ { :cmd => 'ps1', :args => script } ]
      commands.to_json
    end

    def promise_copy_out_src_dir
      "@ROOT@/"
    end

    def container_relative_path(root, *parts)
      #container_relative_path = super(root, *parts)
      container_relative_path = File.join(root, *parts)
      return container_relative_path;
    end

    def promise_exec_hook_script(key)
      Promise.new do |p|
        if bootstrap.config['hooks'] && bootstrap.config['hooks'][key]
          script_path = bootstrap.config['hooks'][key]
          if File.exist?(script_path)
            script = build_promise_exec_hook_script(script_path)
            container.run_script(:app, script)
          else
            log(:warn, "droplet.hook-script.missing", :hook => key, :script_path => script_path)
          end
        end
        p.deliver
      end
    end
  end
end

