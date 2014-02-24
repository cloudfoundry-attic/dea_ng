require "language_pack/c_base"
require "fileutils"

module LanguagePack
  class CbServer < CBase

    def self.use?
      File.exists?("bin/cb-server") 
    end

    def name
      "cb-server"
    end

    def do_compile
      create_directories
      unpack_py
    end

    def create_directories
       FileUtils.mkdir_p("log")	
       FileUtils.mkdir_p("conf/exp/exp_path")	
    end

    def unpack_py
      %x{ cd opbin && tar zxf python2.7.2.tar.gz } 
    end

  end
end
