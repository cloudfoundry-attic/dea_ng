require "pathname"
require "language_pack/c_base.rb"
require "language_pack/cb_as.rb"
require "language_pack/cb_server.rb"
require "language_pack/dan_bs.rb"
require "language_pack/dn_as.rb"

# General C Pack module
module LanguagePack

  # detects which C pack to use
  # @param [Array] first argument is a String of the build directory
  # @return [Pack] the {CPack} detected
  def self.detect(*args)
    Dir.chdir(args.first)
    pack = [ CbAs, CbServer, DanBs, DnAs ].detect do |klass|
      klass.use?
    end
    pack ? pack.new(*args) : nil
  end

end


