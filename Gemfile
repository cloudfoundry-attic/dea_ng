source "https://rubygems.org"

gem "eventmachine", :git => "git://github.com/cloudfoundry/eventmachine.git", :branch => "release-0.12.11-cf"
gem "em-http-request", "~> 1.0.0.beta.3", :require => "em-http"

gem "nats", :require => "nats/client"
gem "em-warden-client", :git => "git://github.com/cloudfoundry/warden.git", :ref => "1df76f80"
gem "em-posix-spawn", :git => "git://github.com/cloudfoundry/common.git",   :ref => "3f6636fc"

gem "rack", :require => ["rack/utils", "rack/mime"]
gem "rake"
gem "thin"
gem "yajl-ruby", :require => ["yajl", "yajl/json_gem"]

gem "vcap_common", "~> 1.0.8", :git => "git://github.com/cloudfoundry/vcap-common.git", :ref => "9673dced"
gem "vcap_logging", :require => ["vcap/logging"], :git => "git://github.com/cloudfoundry/common.git", :ref => "3f6636fc"

group :test do
  gem "rspec"
end
