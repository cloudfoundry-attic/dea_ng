require "rspec"
require "rspec/autorun"

Dir["./spec/support/**/*.rb"].map { |f| require f }

RSpec.configure do |config|
  config.include(Helpers)
end
