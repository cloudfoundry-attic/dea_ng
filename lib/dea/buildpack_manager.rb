module Dea
  class BuildpackManager
    VENDOR_DIR = ""
    def add_buildpack(message)
      buildpack_name = message.data["name"]
      return false if buildpack_name =~ %r|[\./]|

      buildpack_url = message.data["url"]
      buildpack_path = File.expand_path("../../../buildpacks/vendor/#{buildpack_name}", __FILE__)

      return true if buildpack_exists?(buildpack_name)

      system("git clone --recursive #{buildpack_url} #{buildpack_path}")
    end

    private

    def buildpack_exists?(buildpack_name)
      existing_buildpacks.include?(buildpack_name)
    end

    def existing_buildpacks
      vendor_dir = File.expand_path("../../../buildpacks/vendor", __FILE__)
      Dir.entries(vendor_dir).select {|entry| (entry !='.' && entry != '..') }
    end
  end
end
