# coding: UTF-8

require "dea/promise"

module Helpers
  def delivering_promise(value = nil)
    Dea::Promise.new { |p| p.deliver(value) }
  end

  def failing_promise(value)
    Dea::Promise.new { |p| p.fail(value) }
  end
end
