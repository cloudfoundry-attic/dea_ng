require 'logger'

module VCAP
  module Dea
  end
end

class VCAP::Dea::ResourceTracker
  attr_reader :reserved, :max

  #resources = {:memory => val, :disk => val, :instances => val}
  def initialize(resources, logger = nil)
    @logger = logger || Logger.new(STDOUT)
    @max = resources
    @reserved = {:memory => 0, :disk => 0, :instances => 0}
    raise "invalid input" unless @max.keys == @reserved.keys
    @logger.info("Available Resources: #{@max}")
  end

  def reserve(request)
    insufficient_resources = false

    request.each do |name, amount|
      if (@reserved[name] + amount) > @max[name]
        @logger.info("insufficient resource #{name} to satisfy request #{request}.")
        insufficient_resources = true
        break
      end
    end

    if insufficient_resources
      nil
    else
      request.each {|name,amount| @reserved[name] += amount}
      @logger.debug("resources reserved: #{request}")
      request
    end
  end

  def release(request)
    request.each do |name, amount|
      if (@reserved[name] - amount) < 0
        @logger.error("resource underflow error")
        @reserved[name] = 0
      else
        @reserved[name] -= amount
      end
    end
    @logger.debug("resources released: #{request}")
  end

  def available
    result = Hash.new
    @max.each_key {|name| result[name] = @max[name] - @reserved[name]}
    result
  end

end





