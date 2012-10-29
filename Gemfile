source "https://rubygems.org"

gem "eventmachine"
gem "em-http-request", "~> 1.0.0.beta.3", :require => "em-http"

gem "em-warden-client", :git => "https://github.com/cloudfoundry/warden.git"
gem "warden-client", :git => "https://github.com/cloudfoundry/warden.git"
gem "warden-protocol", :git => "https://github.com/cloudfoundry/warden.git"

gem "nats", :require => "nats/client"

gem "rack", :require => ["rack/utils", "rack/mime"]
gem "rake"
gem "thin"
gem "yajl-ruby", :require => ["yajl", "yajl/json_gem"]
gem "grape", :git => "https://github.com/intridea/grape.git"

gem "vcap_common", :git => "https://github.com/cloudfoundry/vcap-common.git"
gem "steno", :git => "https://github.com/cloudfoundry/steno.git"

gem "sys-filesystem"

group :test do
  gem "rspec"
  gem "rack-test"
  gem "rcov"
  gem "ci_reporter"
end
