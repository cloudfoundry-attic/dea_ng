[![Build Status](https://travis-ci.org/cloudfoundry/dea_ng.png)](https://travis-ci.org/cloudfoundry/dea_ng)

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


## Running DEA on a non-linux system (with Vagrant)

When contributing to DEA it's useful to run it as a standalone
component. Here is how to do that:

- `librarian-chef install` from `chef` director

- `vagrant up` to start VM that will run DEA and its dependencies.
  (Vagrantfile is currently set up to use Ubuntu 10.04.)

- `vagrant ssh` to get inside the VM

- `/dea` contains mounted copy of dea_ng source code

- `/warden` contains cloned version of Warden

- Run `sudo su -`

- Run `foreman start` to start dea_ng components specified in Procfile


## Staging

See [staging.rb](lib/dea/responders/staging.rb) for staging flow.

#### NATS Messaging

- `staging.advertise`: Stagers (now DEA's) broadcast their capacity/capability

- `staging.locate`: Stagers respond to any message on this subject with a
  `staging.advertise` message (CC uses this to bootstrap)

- `staging.<uuid>.start`: Stagers respond to requests on this subject to stage apps

- `staging`: Stagers (in a queue group) respond to requests to stage an app
  (old protocol)