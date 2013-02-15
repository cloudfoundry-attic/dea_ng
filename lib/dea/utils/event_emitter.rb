# coding: UTF-8

module Dea
  module EventEmitter
    def on(event, cb = nil, &blk)
      _listeners[event] << (cb || blk)
    end

    def emit(event, *args)
      _listeners[event].each { |l| l.call(*args) }
    end

    private

    def _listeners
      @_listeners ||= Hash.new { |h,k| h[k] = [] }
    end
  end
end
