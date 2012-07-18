# coding: UTF-8

require "rspec"
require "rspec/autorun"
require "steno"

Dir["./spec/support/**/*.rb"].map { |f| require f }

RSpec.configure do |config|
  config.include(Helpers)

  config.before do
    steno_config = {
      :default_log_level => :all,
      :codec => Steno::Codec::Json.new,
      :context => Steno::Context::Null.new
    }

    if ENV.has_key?("V")
      steno_config[:sinks] = [Steno::Sink::IO.new(STDOUT)]
    end

    Steno.init(Steno::Config.new(steno_config))
  end
end
