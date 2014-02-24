require "jpaas_pack/java"
require "jpaas_pack/package_fetcher"
require "fileutils"

# TODO logging
module JpaasPack
  class JavaStandalone < Java
    include JpaasPack::PackageFetcher

    def self.use?
      Dir.glob("**/*.jar").any?
    end

    def name
      "Java Standalone"
    end

    def do_compile
        install_java
        setup_profiled
        create_droplet_yaml
    end

    def java_opts
      # TODO jconsole and rpc 
      super.merge({ "-Dhttp.port=" => "$PORT" })
    end

  end
end
