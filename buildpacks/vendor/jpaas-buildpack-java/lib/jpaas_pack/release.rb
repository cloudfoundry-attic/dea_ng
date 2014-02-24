require "yaml"

module JpaasPack
  module Release
    DEFAULT_RELEASE_FILE = "Release".freeze

    def release_file
      File.join(build_path,DEFAULT_RELEASE_FILE)
    end

    def release_info
      @release_info ||= File.exists?(release_file) ? YAML.load_file(release_file) : {}
      raise "#{DEFAULT_RELEASE_FILE}: invalid yaml format" unless @release_info.kind_of?(Hash)
      @release_info
    end

  end
end
