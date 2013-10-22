require "open3"
require 'rbconfig'

module Buildpacks
  class Installer < Struct.new(:path, :app_dir, :cache_dir)
    WINDOWS = (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/)

    def detect
      @detect_output, status = Open3.capture2 command('detect')
      status == 0
    end

    def name
      @detect_output ? @detect_output.strip : nil
    end

    def compile
      ok = system "#{command('compile')} #{cache_dir}"
      raise "Buildpack compilation step failed:\n" unless ok
    end

    def release_info
      output, status = Open3.capture2 command("release")
      raise "Release info failed:\n#{output}" unless status == 0
      YAML.load(output)
    end

    private

    def command(command_name)
      cmd = File.join(path, 'bin', command_name)
      if WINDOWS
        cmd = "ruby #{cmd}"
      end
      "#{cmd} #{app_dir}"
    end
  end
end
