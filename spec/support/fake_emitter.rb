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

  def emit_value_metric(name, value, unit)
    return unless name && value && unit
    unless @messages[name]
      @messages[name] = []
    end
    @messages[name].push({:value => value, :unit => unit})
  end

  def emit_counter(name, delta)
    return unless name && delta
    unless @messages[name]
      @messages[name] = []
    end
    @messages[name].push({:delta => delta})
  end

  def emit_container_metric(app_id, instanceIndex, cpuPercentage, memoryBytes, diskBytes)
    return unless app_id && instanceIndex && cpuPercentage && memoryBytes && diskBytes
    unless @messages[app_id]
      @messages[app_id] = []
    end
    @messages[app_id].push(
      {
        :app_id => app_id,
        :instanceIndex => instanceIndex,
        :cpuPercentage => cpuPercentage,
        :memoryBytes => memoryBytes,
        :diskBytes => diskBytes
      })
  end

  def reset
    @messages = Hash.new
    @error_messages = Hash.new
  end
end
