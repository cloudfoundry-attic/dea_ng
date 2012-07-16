require "rspec"
require "rspec/autorun"
require "steno"

Dir["./spec/support/**/*.rb"].map { |f| require f }

RSpec.configure do |config|
  config.include(Helpers)

  config.before do
    config = Steno::Config.new \
      :default_log_level => :all,
      :codec => Steno::Codec::Json.new,
      :context => Steno::Context::Null.new

    Steno.init(config)
  end
end
