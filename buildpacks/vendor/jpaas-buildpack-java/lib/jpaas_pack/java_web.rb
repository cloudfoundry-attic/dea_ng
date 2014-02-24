require "jpaas_pack/java_web"
require "jpaas_pack/release"

require "fileutils"

module JpaasPack
  class JavaWeb < Java

    include JpaasPack::PackageFetcher
    include JpaasPack::Release

    DEFAULT_TOMCAT_VERSION =  "6.0".freeze
    DEFAULT_TOMCAT_PORT =  "8080".freeze


    def self.use?
      File.exists?("WEB-INF/web.xml") || File.exists?("webapps/ROOT/WEB-INF/web.xml")
    end

    def name
      "Java Web:Tomcat"
    end

    def do_compile
      install_java
      install_tomcat
      remove_tomcat_files
      copy_webapp_to_tomcat
      move_tomcat_to_root
      setup_profiled
      create_droplet_yaml
    end

    def install_tomcat
      FileUtils.mkdir_p tomcat_dir
      tomcat_tarball="#{tomcat_dir}/tomcat.tar.gz"

      download_tomcat tomcat_tarball

      puts "Unpacking Tomcat to #{tomcat_dir}"
      puts  "tar xzf #{tomcat_tarball} -C #{tomcat_dir} &&  mv #{tomcat_dir}/apache-tomcat*/* #{tomcat_dir}"
      run_with_err_output("tar xzf #{tomcat_tarball} -C #{tomcat_dir} && mv #{tomcat_dir}/apache-tomcat*/* #{tomcat_dir} && rm -rf #{tomcat_dir}/apache-tomcat*")
      FileUtils.rm_rf tomcat_tarball
      unless File.exists?("#{tomcat_dir}/bin/catalina.sh")
        puts "Unable to retrieve Tomcat"
        exit 1
      end
    end
    
    def tomcat_version
      release_info["tomcat"] || DEFAULT_TOMCAT_VERSION
    end

    def download_tomcat(tomcat_tarball)
      puts "Downloading Tomcat..."
      fetched_package = fetch_tomcat_package(tomcat_version)
      unless File.exists?(fetched_package)
        puts "Unable to download Tomcat"
        exit 1
      end
      puts "Downloading Tomcat is done"
      FileUtils.mv fetched_package, tomcat_tarball
    end

    def remove_tomcat_files
      %w[NOTICE RELEASE-NOTES RUNNING.txt LICENSE temp/. webapps/. work/. logs].each do |file|
        FileUtils.rm_rf("#{tomcat_dir}/#{file}")
      end
    end

    def tomcat_dir
      ".tomcat"
    end

    def webapp_path
      File.join(build_path,"webapps","ROOT")
    end

    def copy_webapp_to_tomcat
      run_with_err_output("mkdir -p #{tomcat_dir}/webapps/ROOT && mv * #{tomcat_dir}/webapps/ROOT")
    end

    def move_tomcat_to_root
      run_with_err_output("mv #{tomcat_dir}/* . && rm -rf #{tomcat_dir}")
    end

    def java_opts
      #TODO jconsole port
      #Don't override Tomcat's temp dir setting
      opts = super.merge({ "-Dport.http.nonssl=" => "#{DEFAULT_TOMCAT_PORT}" })
      opts.delete("-Djava.io.tmpdir=")
      opts
    end

    def default_process_types
      {
        "web" => "./bin/catalina.sh run"
      }
    end

    def droplet_info
    #todo: using "state_file" => "tomcat.state" for health check
      {
        "raw_ports" => {
          "http" => {
            "port" => DEFAULT_TOMCAT_PORT.to_i,
            "bns" => false,
            "http" => true
          }
        }
      }
    end

  end
end
