# start warden
cd /warden/warden
bundle install
rvmsudo bundle exec rake warden:start[config/test_vm.yml] 2>&1 > /tmp/warden.log &

# start the DEA's dependencies
cd /vagrant
bundle install
foreman start > /tmp/foreman.log &
