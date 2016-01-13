source 'https://rubygems.org'

gem 'eventmachine', '~> 1.0.3'
gem 'em-http-request'
gem 'em-synchrony'

gem 'em-warden-client', git: 'https://github.com/cloudfoundry/warden.git'
gem 'warden-client', git: 'https://github.com/cloudfoundry/warden.git'
gem 'warden-protocol', git: 'https://github.com/cloudfoundry/warden.git'

gem 'nats', '>= 0.5.0', '< 0.6', require: 'nats/client'
gem 'rack', require: %w[rack/utils rack/mime]
gem 'rake'
gem 'thin'
gem 'yajl-ruby', require: %w[yajl yajl/json_gem]
gem 'grape', git: 'https://github.com/intridea/grape.git'

gem 'vcap_common'
gem 'steno', '~> 1.1.0'

gem 'uuidtools'
gem 'nokogiri', '~> 1.6.2'
gem 'vmstat'

gem 'loggregator_emitter'

gem 'sys-filesystem'

group :test do
  gem 'codeclimate-test-reporter', require: false
  gem 'ci_reporter'
  gem 'foreman'
  gem 'net-ssh'
  gem 'patron'
  gem 'rack-test'
  gem 'rspec'
  gem 'rspec-fire', require: false
  gem 'rubyzip'
  gem 'sinatra'
  gem 'timecop'
  gem 'webmock'
end
