# coding: UTF-8

require "membrane"
require "steno"
require "steno/core_ext"

module Dea
  class Runtime
    class BaseError < StandardError; end
    class NotFoundError < BaseError; end
    class VersionError < BaseError; end
    class AdditionalCheckError < BaseError; end

    def self.schema
      ::Membrane::SchemaParser.parse do
        {
          "executable"                  => String,
          "version_output"              => String,
          "version_flag"                => String,
          optional("additional_checks") => String,
          optional("environment")       => dict(String, String),
          optional("debug_env")         => dict(String, [String]),
        }
      end
    end

    attr_reader :config

    def initialize(config)
      @config = config.dup

      # Stringify environment map
      if @config["environment"].kind_of?(Hash)
        @config["environment"].keys.each do |key|
          @config["environment"][key] ||= ""
        end
      end
    end

    def executable
      config["executable"]
    end

    def environment
      config["environment"] || {}
    end

    def debug_environment(mode)
      env = (config["debug_env"] || {})[mode] || []

      Hash[env.map do |e|
        pair = e.split("=", 2)
        pair[0] = pair[0].to_s
        pair[1] = pair[1].to_s
        pair
      end]
    end

    def dirname
      File.expand_path("../..", executable)
    end

    def validate
      self.class.schema.validate(config)

      validate_executable
      validate_version
      validate_additional_checks
    end

    def validate_executable
      if executable =~ /\//
        executable_path = File.expand_path(executable)
      else
        executable_path =
          ENV["PATH"].
            split(":").
            map { |path| File.expand_path(executable, path) }.
            find { |path| File.executable?(path) }
      end

      if executable_path && File.executable?(executable_path)
        config["executable"] = executable_path
      else
        raise NotFoundError, "Cannot find #{executable.inspect}"
      end

      nil
    end

    def validate_version
      actual_output = run(executable, config["version_flag"])
      unless $?.success?
        raise VersionError, "Runtime exited with non-zero status #{executable}"
      end

      expected_output = Regexp.compile(/#{config["version_output"]}/m)
      unless expected_output.match(actual_output)
        raise VersionError, "Version mismatch for #{executable} (expected: #{expected_output}, actual: #{actual_output})"
      end
    end

    def validate_additional_checks
      if config["additional_checks"]
        additional_checks_output = run(executable, config["additional_checks"])
        unless $?.success?
          raise AdditionalCheckError, "Runtime exited with non-zero status #{executable}"
        end

        unless additional_checks_output =~ /true/i
          raise AdditionalCheckError, "Additional checks failed for #{executable} (expected: /true/i, actual: #{additional_checks_output})"
        end
      end
    end

    private

    def run(*args)
      `env -i HOME=$HOME #{args.join(" ")} 2>&1`.chomp
    end
  end
end
