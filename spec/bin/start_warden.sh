#!/bin/bash

set -e
set -x

# as configured in the Vagrant VM
WARDEN_DIR=/warden/warden

cd $WARDEN_DIR
bundle exec rake warden:start[config/dea_vm.yml]
