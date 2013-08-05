module Buildpacks
  class Procfile
    def initialize(path)
      @path = path
    end

    def contents
      @contents ||= begin
        if File.exists?(@path)
          contents = YAML.load(File.read(@path))
          raise(ArgumentError, "Invalid Procfile format. Please ensure it is a valid YAML hash") unless contents.is_a? Hash
          contents
        end
      end
    end

    def web
      contents["web"] if contents
    end
  end
end