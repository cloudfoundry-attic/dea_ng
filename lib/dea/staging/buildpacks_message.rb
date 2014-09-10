require "dea/starting/start_message"
require "steno"
require "steno/core_ext"

class BuildpacksMessage
  def initialize(message)
    @message = message
  end

  def buildpacks
    (@message || []).map do |buildpack|
      begin
        { url: URI(buildpack["url"]), key: buildpack["key"] }
      rescue => e
        logger.log_exception(e)
      end
    end.compact
  end
end
