source "https://rubygems.org"

gem "eventmachine"
gem "em-http-request"

gem "em-warden-client", :git => "https://github.com/cloudfoundry/warden.git"
gem "warden-client", :git => "https://github.com/cloudfoundry/warden.git"
gem "warden-protocol", :git => "https://github.com/cloudfoundry/warden.git"

gem "nats", :require => "nats/client"
gem "rack", :require => %w[rack/utils rack/mime]
gem "rake"
gem "thin"
gem "yajl-ruby", :require => %w[yajl yajl/json_gem]
gem "grape", :git => "https://github.com/intridea/grape.git"

gem "vcap_common", :git => "https://github.com/cloudfoundry/vcap-common.git"
gem "steno", "~> 1.1.0", :git => "https://github.com/cloudfoundry/steno.git"

gem "uuidtools", "~> 2.1.2"
gem "nokogiri", ">= 1.4.4"
gem "vmstat"

gem "sys-filesystem"

group :test do
  gem "timecop"
  gem "patron"
  gem "foreman"
  gem "sinatra"
  gem "librarian"
  gem "rspec"
  gem "rack-test"
  gem "rcov"
  gem "ci_reporter"
end
