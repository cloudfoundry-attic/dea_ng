module JpaasPack
  module PackageFetcher

    PACKAGES_CONFIG = File.join(File.dirname(__FILE__), "../../config/packages.yml")

    attr_writer :buildpack_cache_dir

    def buildpack_cache_dir
      @buildpack_cache_dir || "/var/vcap/packages/buildpack_cache"
    end

    def fetch_jdk_package(version)
      puts packages_config["jdks"]
      jdk_package = packages_config["jdks"].find { |k| k["version"] == version }
      raise "Unsupported Java version: #{version}" unless jdk_package
      fetch_package(jdk_package["jdk"])
    end

    def fetch_tomcat_package(version)
      tomcat_package = packages_config["tomcats"].find { |k| k["version"] == version }
      puts tomcat_package["tomcat"]
      raise "Unsupported Tomcat version: #{version}" unless tomcat_package
      fetch_package(tomcat_package["tomcat"])
    end

    def fetch_package(filename, url=packages_config["url"])
      fetch_from_local(filename)
      #fetch_from_buildpack_cache(filename) ||
      #fetch_from_curl(filename, url)
    end

    def fetch_package_and_untar(filename, url=VENDOR_URL)
      fetch_package(filename, url) && run("tar xzf #{filename}")
    end

    def packages_config
      YAML.load_file(File.expand_path(PACKAGES_CONFIG))
    end

    private

    def fetch_from_buildpack_cache(filename)
      file_path = File.join(buildpack_cache_dir, filename)
      return unless File.exist?(file_path)
      puts "Copying #{filename} from the buildpack cache ..."
      FileUtils.cp(file_path, ".")
      File.expand_path(File.join(".", filename))
    end

    def fetch_from_curl(filename, url)
      puts "Downloading #{filename} from #{url} ..."
      system("curl #{url}/#{filename}  -s  -o #{filename}")
      File.exist?(filename) ? filename : nil
    end
     
    def fetch_from_local(filename)
      file_path=File.join(File.expand_path('../../../resources/', __FILE__),filename)
      puts file_path
      return unless File.exist?(file_path)
      puts "Copy #{filename} from local buildpack ..."
      FileUtils.cp(file_path, ".")
      puts File.expand_path(File.join(".", filename))
      File.expand_path(File.join(".", filename))
    end

  end
end
