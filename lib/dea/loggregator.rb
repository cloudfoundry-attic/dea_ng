module Dea
  class Loggregator

    @@emitter = nil
    @@staging_emitter = nil

    def self.emit(app_id, message)
      @@emitter.emit(app_id, message) if @@emitter
    end

    def self.emit_error(app_id, message)
      @@emitter.emit_error(app_id, message) if @@emitter
    end

    def self.emitter=(emitter)
      @@emitter = emitter
    end

    def self.staging_emitter=(emitter)
      @@staging_emitter = emitter
    end

    def self.staging_emit(app_id, message)
      @@staging_emitter.emit(app_id, message) if @@staging_emitter
    end

    def self.staging_emit_error(app_id, message)
      @@staging_emitter.emit_error(app_id, message) if @@staging_emitter
    end
  end
end
