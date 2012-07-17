source "https://rubygems.org"

gem "eventmachine", :git => "https://github.com/cloudfoundry/eventmachine.git", :branch => "release-0.12.11-cf"
gem "em-http-request", "~> 1.0.0.beta.3", :require => "em-http"

gem "nats", :require => "nats/client"
gem "em-warden-client", :git => "https://github.com/cloudfoundry/warden.git", :ref => "1df76f80"
gem "em-posix-spawn", :git => "https://github.com/cloudfoundry/common.git",   :ref => "3f6636fc"

gem "rack", :require => ["rack/utils", "rack/mime"]
gem "rake"
gem "thin"
gem "yajl-ruby", :require => ["yajl", "yajl/json_gem"]

gem "vcap_common", :git => "https://github.com/cloudfoundry/vcap-common.git", :ref => "5334b662"
gem "steno", :git => "https://github.com/cloudfoundry/steno.git", :ref => "a1a602a0"

group :test do
  gem "rspec"
end
