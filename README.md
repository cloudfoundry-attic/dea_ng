# dea_ng

This repository contains the code for the Droplet Execution Agent (DEA)
and related components.

## Components

### DEA

The DEA itself is written in Ruby and takes care of managing an
application instance's lifecycle. It can be instructed by the [Cloud
Controller][cc] to start and stop application instances. It keeps track
of all started instances, and periodically broadcasts messages about
their state over [NATS][nats] (meant to be picked up by the [Health
Manager][hm]).

The advantages of this generation of the DEA over the previous (and
first) generation DEA is that is more modular and has better test
coverage. A breaking change between the two is that this version of the
DEA depends on [Warden][warden] to run application instances.

[cc]: https://github.com/cloudfoundry/cloud_controller_ng
[nats]: https://github.com/derekcollison/nats
[hm]: https://github.com/cloudfoundry/health_manager
[warden]: https://github.com/cloudfoundry/warden

### Directory server

The directory server is written in Go and can be found in the `go/`
directory. It is a replacement for the older directory server that was
embedded in the DEA itself.

Requests for directories/files are handled by the DEA, which responds
with a HTTP redirect to a URL that hits the directory server directly.
The URL is signed by the DEA, and the directory server checks the
validity of the URL with the DEA before serving it.

## Usage

You can run the dea executable at the command line by passing the path
to a YAML configuration file:

```shell
bin/dea config/dea.yml
```

### Configuration

The following is a partial list of the keys that are read from the YAML file:

* `logging` - a [Steno configuration](http://github.com/cloudfoundry/steno#from-yaml-file)
* `nats_servers` - an array of URIs of the form `nats://host:port` that the DEA will use to connect to NATS.
* `warden_socket` - the path to a unix domain socket that the DEA will use to communicate to a warden server.
* `instance.nproc_limit` - sets the system ulimit for the number of processes within an application container

### Running the DEA in the provided Vagrant VM

When contributing to DEA it is useful to run it as a standalone
component.

In the following examples, we assume that you have cloned the `cf-release` repository into `~/workspace/cf-release`.
If you use a different path, you need to adjust the path in the DEA `Vagrantfile`
to point to the correct location of `cf-release`, otherwise you will most likely get this error when you try
to create the [Vagrant][vagrant] VM:

```
vm:
* The host path of the shared folder is missing: ~/workspace/cf-release
```

In this case, simply edit the `Vagrantfile` to insert the correct path and retry creating the VM.

If you are able to bring up the VM, but the tests terminate quickly with this error message:

```
bash: /var/cf-release/src/dea-hm-workspace/src/dea_next/bin/start_warden_and_run_specs.sh: No such file or directory
```
then either the repository is incomplete/corrupted, or the directory mounted simply does not actually point to
the cloned repository.  Check that the location into which you've cloned `cf-release` matches the source path
for the mount in the `Vagrantfile`, remove the existing VM with `vagrant destroy` (be sure to run this from the
`dea_next` directory so that you do not accidentally delete other VMs you may have running), and then retry
VM creation and test execution.


### Testing

The DEA integration tests run against real Warden, directory, and NATS servers, so they must be run
in a [Vagrant][vagrant] VM. The `bin` directory contains a helper script that runs the entire DEA test suite:

[vagrant]: http://docs.vagrantup.com/v2/installation/index.html

```
bash

# Checkout the required repos
mkdir ~/workspace
cd ~/workspace
git clone https://github.com/cloudfoundry/cf-release
cd cf-release
scripts/update
bosh sync blobs # required to download rootfs blob
cd src/dea-hm-workspace
git checkout master
git submodule update --init --recursive
cd src/dea_next; git checkout master

# Verify that Vagrant version is at least 1.5
vagrant --version

# Ensure the guest additions plugin is installed
vagrant plugin install vagrant-vbguest

# Run test suite in Vagrant vm
bin/run_specs_in_vm.sh
```
This will stand up the test virtual machine (if it is not already running) and run both the unit and integration
suites.  Note that the integration tests stage and run real applications, which requires an internet connection.
They take 5-10 minutes to run, depending on your connection speed.

To run tests individually, there is a bit of setup:

```bash
#start vagrant
vagrant up

#shell into the VM
vagrant ssh

#create rootfs
mkdir -p /tmp/warden/rootfs
sudo tar -xvf /var/cf-release/.blobs/`basename $(readlink /var/cf-release/blobs/rootfs/*)` -C /tmp/warden/rootfs > /dev/null

#start warden
cd /var/cf-release/src/warden/warden
sudo bundle install
bundle exec rake setup:bin
sudo bundle exec rake warden:start[config/linux.yml] &> /tmp/warden.log &

# start the DEA's dependencies
cd /var/cf-release/src/dea_next
export GOPATH=$PWD/go
go get github.com/nats-io/gnatsd
sudo bundle install
sudo bundle exec foreman start &> /tmp/foreman.log &

#To run the tests (unit or integration - these must be run separately if run as suites):
bundle install
bundle exec rspec spec/unit
bundle exec rspec spec/integration
```

To watch the internal NATS traffic while the tests run, do this
in another ssh session:

```
nats-sub ">" -s nats://localhost:4222
```
## Testing the directory server

Running the dea unit and integration tests via the `bin/run_specs_in_vm.sh` script
will also run the directory server tests, but if you want to run tests against just the directory
server, you can do the following once you have checked out the repository (replace
`$DEA_REPO_ROOT` with the location of the `dea_ng` repo - in the above examples, it is
`~/workspace/cf-release/src/dea-hm-workspace/src/dea_next`:

cd $DEA_REPO_ROOT
export GOPATH=$PWD/go
go test -i -race directoryserver
go test -v -race directoryserver

## Staging

See [staging.rb](lib/dea/responders/staging.rb) for staging flow.

### NATS Messaging

- `staging.advertise`: Stagers (now DEA's) broadcast their capacity/capability

- `staging.locate`: Stagers respond to any message on this subject with a
  `staging.advertise` message (CC uses this to bootstrap)

- `staging.<uuid>.start`: Stagers respond to requests on this subject to stage apps

## Warden rootfs

For details about how to use and update the Warden rootfs, see [the stacks documentation](https://github.com/cloudfoundry/stacks).

## Logs

The DEA's logging is handled by [Steno](https://github.com/cloudfoundry/steno).
The DEA can be configured to log to a file, a syslog server or both. If neither is provided,
it will log to its stdout.

The following log levels exist, shown with an example of what they are used for:
* `error` - DEA failed to download builpack cache, cannot create PID file
* `warn` - DEA failed to destroy a warden container, DEA received invalid JSON message over NATS
* `info` - DEA is shutting down, DEA received a request to stage/run an app, but didn't have the resources
* `debug2` - DEA received request for instance information, but was not running the specified app
* `debug` - DEA saved a snapshot, downloaded a droplet

### Log Topics

* droplet.* - logging relevant to an app's instance
* staging.* - logging relevant to the staging of an app's bits
* dea.* - component-level logging for the DEA itself

## Contributing

Please read the [contributors' guide](https://github.com/cloudfoundry/dea_ng/blob/master/CONTRIBUTING.md)
