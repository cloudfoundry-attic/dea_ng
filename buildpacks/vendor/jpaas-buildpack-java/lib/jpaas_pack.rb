require "jpaas_pack/java_standalone"
require "jpaas_pack/java_web"

# General Java Pack module
module JpaasPack

  # detects which pack to use
  # @param [Array] first argument is a String of the build directory
  # @return [Pack] the {Pack} detected
  def self.detect(*args)
    Dir.chdir(args.first)

    pack = [ JavaWeb, JavaStandalone ].detect do |klass|
      klass.use?
    end

    pack ? pack.new(*args) : nil
  end

end


