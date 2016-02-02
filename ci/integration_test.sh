#!/bin/bash
set -ex

source ~/.bashrc

function permit_device_control() {
    local devices_mount_info=$(cat /proc/self/cgroup | grep devices)

    if [ -z "$devices_mount_info" ]; then
        # cgroups not set up; must not be in a container
        return
    fi

    local devices_subsytems=$(echo $devices_mount_info | cut -d: -f2)
    local devices_subdir=$(echo $devices_mount_info | cut -d: -f3)

    if [ "$devices_subdir" = "/" ]; then
        # we're in the root devices cgroup; must not be in a container
        return
    fi

    cgroup_dir=${RUN_DIR:-}/devices-cgroup

    if [ ! -e ${cgroup_dir} ]; then
        # mount our container's devices subsystem somewhere
        mkdir ${cgroup_dir}
    fi

    if ! mountpoint -q ${cgroup_dir}; then
        mount -t cgroup -o $devices_subsytems none ${cgroup_dir}
    fi

    # permit our cgroup to do everything with all devices
    echo a > ${cgroup_dir}${devices_subdir}/devices.allow || true
}

function create_loop_devices() {
    amt=$1
    for i in $(seq 0 $amt); do
        mknod -m 0660 /dev/loop$i b 7 $i || true
    done
}

permit_device_control
create_loop_devices 100

mkdir -p /tmp/warden
mount -o size=4G,rw -t tmpfs tmpfs /tmp/warden

rootfs_loopdev=$(losetup -f)
dd if=/dev/zero of=/tmp/warden/rootfs.img bs=1024 count=1048576
losetup ${rootfs_loopdev} /tmp/warden/rootfs.img
mkfs -t ext4 -m 1 -v ${rootfs_loopdev}
mkdir /tmp/warden/rootfs
mount -t ext4 ${rootfs_loopdev} /tmp/warden/rootfs

containers_loopdev=$(losetup -f)
dd if=/dev/zero of=/tmp/warden/containers.img bs=1024 count=1048576
losetup ${containers_loopdev} /tmp/warden/containers.img
mkfs -t ext4 -m 1 -v ${containers_loopdev}
mkdir /tmp/warden/containers
mount -t ext4 ${containers_loopdev} /tmp/warden/containers

apt-get update
apt-get install -y iptables quota --no-install-recommends

export PATH=$PATH:/sbin

git config --system user.email "nobody@example.com"
git config --system user.name "Anonymous Coward"

rm -f dea-hm-workspace/bin/*
rm -rf dea-hm-workspace/src/dea_next/go/{bin,pkg}/*

export GOPATH=$PWD/dea-hm-workspace
export PATH=$PATH:$GOPATH/bin:$HOME/bin

wget -O /tmp/rootfs.tar.gz https://cf-release-blobs.s3.amazonaws.com/e23f42d7-4166-43e3-ba8c-99712048c1a9
tar -xf /tmp/rootfs.tar.gz -C /tmp/warden/rootfs

pushd dea-hm-workspace/src/warden/warden
    chruby $(cat ../.ruby-version)
    gem install bundler --no-doc --no-ri
    sed -i s/254/253/g config/linux.yml
    bundle install
    bundle exec rake setup:bin
    bundle exec rake warden:start[config/linux.yml] &> /tmp/warden.log &
    warden_pid=$!
popd

echo "waiting for warden to come up"
while [ ! -e /tmp/warden.sock ]; do
    sleep 1
done
echo "warden is ready"

cd dea-hm-workspace/src/dea_next/
bundle install --without development

export PATH=$PWD/go/bin:$PATH
bundle exec foreman start &> /tmp/foreman.log &
dea_pid=$!

trap "kill -9 ${dea_pid}; kill -9 ${warden_pid}; umount /tmp/warden/containers; umount /tmp/warden/rootfs; losetup -d ${rootfs_loopdev} || true; losetup -d ${containers_loopdev} || true" EXIT

bundle exec rspec spec/integration --format documentation
