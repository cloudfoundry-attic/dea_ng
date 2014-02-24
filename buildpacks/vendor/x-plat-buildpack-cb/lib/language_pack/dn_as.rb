require "language_pack/c_base"
require "fileutils"

module LanguagePack

  class DnAs < CBase

    def self.use?
      File.exists?("bin/dn-as") 
    end

    def name
      "dn-as"
    end

    def do_compile
        create_directories
    end

    def create_directories
       FileUtils.mkdir_p("log")	
       FileUtils.mkdir_p("conf/exp/exp_path")	
    end

  end
end
