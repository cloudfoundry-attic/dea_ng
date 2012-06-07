module VCAP
  module Dea
    class Error < StandardError; end
    class HandlerError < Error; end
    class WardenError <  Error; end
  end
end
