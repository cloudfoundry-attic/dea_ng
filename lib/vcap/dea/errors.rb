module VCAP
  module Dea
    class Error < StandardError; end
    class HandlerError < Error; end
    class WardenError <  Error; end
    class HttpDownLoadError <  Error; end
  end
end
