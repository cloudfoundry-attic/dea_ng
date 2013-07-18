class RSpecRandFix
  # TODO: figure out how to prevent pollution from rspec-core
  # TODO: Calling Kernel.srand to prevent pollution because rspec-core sets this to the value of 'seed'
  # TODO: => rspec-core-2.13.1/lib/rspec/core/configuration.rb:865 `Kernel.srand RSpec.configuration.seed`

  def self.call_kernel_srand
    Kernel.srand
  end
end