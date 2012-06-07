require 'em/posix/spawn'

require 'vcap/dea/errors'

module VCAP
  module Dea
  end
end

module VCAP::Dea::FiberAwareHelpers
  # Executes the supplied block in EM's threadpool, blocking the current
  # fiber until it completes.
  #
  # @param [Block]  blk  The block to execute
  #
  # @return [Object]     The return value of the block
  def defer(&blk)
    # Executed in EM's thread-pool
    deferred_comp = proc do
      begin
        blk.call
      rescue => e
        e
      end
    end

    # Executed on the main reactor thread
    f = Fiber.current
    resumed_comp = proc do |res|
      f.resume(res)
    end

    EM.defer(deferred_comp, resumed_comp)

    res = Fiber.yield

    if res.kind_of?(Exception)
      raise res
    else
      res
    end
  end

  # Executes commmand in a subprocess, yielding the current fiber until
  # completion.
  #
  # @param  [String]  command  The command to execute.
  #
  # @return [Array]            Tuple of [status, stdout, stderr] where
  #                            status is an instance of Process::Status.
  def sh(command)
    child = EM::POSIX::Spawn::Child.new(command)

    f = Fiber.current
    child.callback { f.resume({}) }
    child.errback {|err| f.resume({:error => err}) }

    result = Fiber.yield

    if result[:error]
      raise VCAP::Dea::Error.new(result[:error].to_s)
    else
      [child.status, child.out, child.err]
    end
  end
end
