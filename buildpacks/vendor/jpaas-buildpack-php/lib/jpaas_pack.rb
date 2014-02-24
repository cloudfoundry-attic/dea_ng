require "jpaas_pack/php_standalone"

# General PHP Web Pack module
module JpaasPack

  # detects which language pack to use
  # @param [Array] first argument is a String of the build directory
  # @return [Pack] the {Pack} detected
  def self.detect(*args)
    Dir.chdir(args.first)

    pack = [ PhpStandalone ].detect do |klass|
      klass.use?
    end

    pack ? pack.new(*args) : nil
  end

end


