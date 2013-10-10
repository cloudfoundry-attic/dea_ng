module Dea
  def self.with_em(&blk)
    if EM.reactor_running?
      blk.call
    else
      EM.run do
        Fiber.new do
          begin
            blk.call
          ensure
            EM.stop
          end
        end.resume
      end
    end
  end
end
