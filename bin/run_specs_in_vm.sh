#!/bin/bash
set -e -x -u

BUILD_TO_RUN_PATH=$1
TEST_INFRA_PATH=$2

vagrant up

vagrant ssh-config > ssh_config
rsync -arq --rsh="ssh -F ssh_config" $BUILD_TO_RUN_PATH/ default:workspace

echo "Your vagrant box is now provisioned in folder $PWD, don't forget to vagrant destroy it eventually."
echo "To connect: vagrant ssh "
echo "To destroy: vagrant destroy"

echo "about to ssh to run tests"
date

if [ -z ${NOTEST:=} ]; then
  vagrant ssh -c "cd ~/workspace && bin/start_warden_and_run_specs.sh"
fi
