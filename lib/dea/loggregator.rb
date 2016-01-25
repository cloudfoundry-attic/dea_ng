module Dea
  class Loggregator
    def self.log_error(e)
      logger.warn("Failed to emit loggregator message. #{e.message}")
    end

    @@emitter = nil
    @@staging_emitter = nil

    def self.emit(app_id, message)
      @@emitter.emit(app_id, message) if @@emitter
    rescue *Errno.constants.map{|e| Errno.const_get(e)} => e
      log_error(e)
    end

    def self.emit_error(app_id, message)
      @@emitter.emit_error(app_id, message) if @@emitter
    rescue *Errno.constants.map{|e| Errno.const_get(e)} => e
      log_error(e)
    end

    def self.emit_value(name, value, unit)
      @@emitter.emit_value_metric(name, value, unit) if @@emitter
    rescue *Errno.constants.map{|e| Errno.const_get(e)} => e
      log_error(e)
    end

    def self.emit_counter(name, delta)
      @@emitter.emit_counter(name, delta) if @@emitter
    rescue *Errno.constants.map{|e| Errno.const_get(e)} => e
      log_error(e)
    end

    def self.emit_container_metric(app_id, instanceIndex, cpuPercentage, memoryBytes, diskBytes)
      @@emitter.emit_container_metric(app_id, instanceIndex, cpuPercentage, memoryBytes, diskBytes) if @@emitter
    rescue *Errno.constants.map{|e| Errno.const_get(e)} => e
      log_error(e)
    end

    def self.emitter=(emitter)
      @@emitter = emitter
    end

    def self.staging_emitter=(emitter)
      @@staging_emitter = emitter
    end

    def self.staging_emit(app_id, message)
      @@staging_emitter.emit(app_id, message) if @@staging_emitter
    rescue *Errno.constants.map{|e| Errno.const_get(e)} => e
      log_error(e)
    end

    def self.staging_emit_error(app_id, message)
      @@staging_emitter.emit_error(app_id, message) if @@staging_emitter
    rescue *Errno.constants.map{|e| Errno.const_get(e)} => e
      log_error(e)
    end
  end
end
