require "jpaas_pack/php"

module JpaasPack 
  
   class PhpStandalone < Php
      
      DEFAULT_PHP_TARBALL = "*php.tar.gz".freeze

      def self.use?
        Dir.glob("#{DEFAULT_PHP_TARBALL}").any? || Dir.glob("**/*.php").any?
      end

      def name
        "Php Standalone"
      end

      def one_tarball?
        Dir.glob("#{DEFAULT_PHP_TARBALL}").size == 1
      end

      def php_tarball
        Dir.glob("#{DEFAULT_PHP_TARBALL}").fetch(0)
      end

      def do_compile
         %x{tar zxf #{php_tarball}} if one_tarball?
         create_droplet_yaml
      end
   end
end
