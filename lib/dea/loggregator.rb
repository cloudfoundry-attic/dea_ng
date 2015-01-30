module Dea
  class Loggregator


    def self.log_network_unreachable
      logger.warn("Failed to emit loggregator message. Network unreachable")
    end

    @@emitter = nil
    @@staging_emitter = nil

    def self.emit(app_id, message)
      @@emitter.emit(app_id, message) if @@emitter
    rescue Errno::ENETUNREACH
      log_network_unreachable
    end

    def self.emit_error(app_id, message)
      @@emitter.emit_error(app_id, message) if @@emitter
    rescue Errno::ENETUNREACH
      log_network_unreachable
    end

    def self.emitter=(emitter)
      @@emitter = emitter
    end

    def self.staging_emitter=(emitter)
      @@staging_emitter = emitter
    end

    def self.staging_emit(app_id, message)
      @@staging_emitter.emit(app_id, message) if @@staging_emitter
    rescue Errno::ENETUNREACH
      log_network_unreachable
    end

    def self.staging_emit_error(app_id, message)
      @@staging_emitter.emit_error(app_id, message) if @@staging_emitter
    rescue Errno::ENETUNREACH
      log_network_unreachable
    end
  end
end
