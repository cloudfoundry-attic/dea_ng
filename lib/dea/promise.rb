module Dea
  class Promise
    def self.resolve(promise)
      f = Fiber.new do
        result = nil

        begin
          result = [nil, promise.resolve]
        rescue => error
          result = [error, nil]
        end

        yield(result)
      end

      f.resume
    end

    attr_reader :elapsed_time

    def initialize(&blk)
      @blk = blk
      @result = nil
      @waiting = []
    end

    def fail(value)
      resume([:fail, value])

      nil
    end

    def deliver(value = nil)
      resume([:deliver, value])

      nil
    end

    def resolve
      if !@result && @waiting.empty?
        run
      end

      if !@result
        wait
      end

      type, value = @result
      raise value if type == :fail
      value
    end

    protected

    def resume(result)
      # Set result once
      unless @result
        @result = result
        @elapsed_time = Time.now - @start_time

        # Resume waiting fibers
        waiting, @waiting = @waiting, []
        waiting.each(&:resume)
      end

      nil
    end

    def run
      f = Fiber.new do
        begin
          @start_time = Time.now
          @blk.call(self)
        rescue => error
          fail(error)
        end
      end

      f.resume
    end

    def wait
      @waiting << Fiber.current
      Fiber.yield
    end
  end
end
