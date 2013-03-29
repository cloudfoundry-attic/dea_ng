#!/bin/bash

set -e

if [ $TRAVIS_BRANCH ]
then
    # Currently warden does not work on Travis
    # so let's just sit here forever until foreman is killed.
    # (Tests that require Warden are skipped.)
    read
else
    # as configured in the Vagrant VM
    WARDEN_DIR=/warden/warden

    cd $WARDEN_DIR
    bundle exec rake warden:start[config/dea_vm.yml]
fi
