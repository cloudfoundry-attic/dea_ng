require 'em-http'
require 'tempfile'

module VCAP
  module Dea
  end
end

module VCAP::Dea::HttpUtil
  class << self
    # Stores the content at uri in a temporary file.
    #
    # @param [String]  uri  Uri to fetch
    # @param [String]  sha  SHA1 of the content at uri
    #
    # @return [String || nil]  Path of the downloaded content on success.
    #                          nil otherwise.
    def download(uri, tmp_dir = nil)
      Tempfile.open("droplet", tmp_dir) do |tmpfile|
        http = EM::HttpRequest.new(uri).get

        f = Fiber.current
        http.stream {|chunk| tmpfile.write(chunk) }
        http.callback { f.resume(true) }
        http.errback { f.resume(false) }

        success = Fiber.yield && (http.response_header.status == 200)
        if success
          tmpfile.path
        else
          nil
        end
      end
    rescue
      tmpfile.unlink if tmpfile
      raise
    end

  end
end
