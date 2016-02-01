class FakeEmitter
  attr_reader :messages, :error_messages

  def initialize
    @messages = Hash.new
    @error_messages = Hash.new
  end

  def emit(app_id, message)
    return unless app_id && message && message.strip.length > 0
    unless @messages[app_id]
      @messages[app_id] = []
    end
    @messages[app_id].push(message)
  end

  def emit_error(app_id, message)
    return unless app_id && message && message.strip.length > 0
    unless @error_messages[app_id]
      @error_messages[app_id] = []
    end
    @error_messages[app_id].push(message)
  end

  def reset
    @messages = Hash.new
    @error_messages = Hash.new
  end
end
