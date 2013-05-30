[![Build Status](https://travis-ci.org/cloudfoundry/dea_ng.png)](https://travis-ci.org/cloudfoundry/dea_ng)
[![Code Climate](https://codeclimate.com/github/cloudfoundry/dea_ng.png)](https://codeclimate.com/github/cloudfoundry/dea_ng)

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
* `nats_uri` - a URI of the form `nats://host:port` that the DEA will use to connect to NATS.
* `warden_socket` - the path to a unix domain socket that the DEA will use to communicate to a warden server.

### Running the DEA in the provided Vagrant VM

When contributing to DEA it's useful to run it as a standalone
component. This test configuration uses [Vagrant 1.1x][vagrant].

[vagrant]: http://docs.vagrantup.com/v2/installation/index.html

Follow these steps to set up DEA to run locally on your computer:

```shell
# clone the repo
git clone http://github.com/cloudfoundry/dea_ng
git submodule update --init
bundle install

# check that your version of vagrant is 1.1 or greater
vagrant --version

# create your test VM
rake test_vm
```

Creating the test VM is likely to take a while.

Note that if the rake test_vm step fails and you see an error like
"undefined method `configure' for Vagrant" or
"found character that cannot start any token while scanning for the next token"
it means the version of Vagrant is too old.
Install Vagrant version 1.1 or higher.

```shell
# initialize the test VM
vagrant up

# shell into the VM
vagrant ssh

# start warden
cd /warden/warden
bundle install
rvmsudo bundle exec rake warden:start[config/test_vm.yml] 2>&1 > /tmp/warden.log &

# start the DEA's dependencies
cd /vagrant
bundle install
foreman start > /tmp/foreman.log &
```

To run the tests (unit, integration or all):
```
bundle exec rspec spec/unit
bundle exec rspec spec/integration
bundle exec rspec
```

Note that the integration tests stage and run real applications, which requires an internet connection.
They take 5-10 minutes to run, depending on your connection speed.

To watch the internal NATS traffic while the tests run, do this
in another ssh session:
```
nats-sub ">" -s nats://localhost:4222
```

## Staging

See [staging.rb](lib/dea/responders/staging.rb) for staging flow.

### NATS Messaging

- `staging.advertise`: Stagers (now DEA's) broadcast their capacity/capability

- `staging.locate`: Stagers respond to any message on this subject with a
  `staging.advertise` message (CC uses this to bootstrap)

- `staging.<uuid>.start`: Stagers respond to requests on this subject to stage apps

- `staging`: Stagers (in a queue group) respond to requests to stage an app
  (old protocol)

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
