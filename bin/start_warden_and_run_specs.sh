#!/bin/bash
set -e -x -u

# Start warden

(
  cd /warden/warden
  sudo bundle install
  sudo bundle exec rake warden:start[config/test_vm.yml] --trace > /dev/null &
)

echo "waiting for warden to come up"
while [ ! -e /tmp/warden.sock ]
do
  sleep 1
done
echo "warden is ready"

# Start foreman (directory server & nats)

sudo bundle install --without development
sudo bundle exec foreman start &

# Run specs

exit_code=0
bundle install
bundle exec rspec spec/unit -fd
exit_code=$?

bundle exec rspec spec/integration -fd
exit_code=$?

echo "Tests finished: killing background jobs:"
jobs

sudo pkill ruby
exit $exit_code
