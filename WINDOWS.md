<!---
  vim:sw=2:ts=2:expandtab:fo=t:tw=144
-->

Installing the DEA on Windows
=============================

* Get the following information about your V2 Cloud Foundry environment:
  * Cloud controller server IP address.
  * NATS user / password (if used)
  * Cloud foundry domain (i.e. `vcap.me`)

It is recommended to use the [installation package](#installation-package) to install the V2 DEA on Windows. If you'd like, you can use the [install
from scratch](#installation-from-scratch) instructions to install everything manually.

Be sure to update your Cloud Controller's `config/stacks.yml` to recognize the `mswin-clr` stack:

```
vagrant@precise64:/vagrant$ cat cloud_controller_ng/config/stacks.yml 
default: lucid64

stacks:
  - name: lucid64
    description: Ubuntu Lucid 64-bit
  - name: mswin-clr
    description: Microsoft .NET / Windows 64-bit
```

Installation package:
-------------------------------------------------

* First, download an archive (7z format) with necessary Ruby binaries and other files from the [Iron Foundry download page.](http://www.ironfoundry.org/download)

* Ensure that git for Windows is installed and in your *system* `PATH`. Git for Windows can be [downloaded here](http://msysgit.github.io/). To confirm,
open a `cmd` window post-installation and run this command:

        C:\>git --version
        git version 1.8.3.msysgit.0

* Extract the downloaded archive to the `C:\` drive, which will add the following top-level directories:

        C:\IronFoundry
        C:\Ruby193

* After extracting ensure that `C:\IronFoundry` and all descendents are owned by the `Administrators` group. Then, ensure that the `NT AUTHORITY\Local Service` user has Full Control access as well. This is the user that the Ruby DEA service runs as.

* Then, run the post-install script as shown below as an administrative user to include `C:\Ruby193\bin` in the system `PATH` and to install the
Ruby DEA as a Windows service. Once installation is complete the service will be set to run automatically with a delayed start.

        C:\>cd C:\IronFoundry\dea_ng\app\win32
        C:\IronFoundry\dea_ng\app\win32>install.cmd

* As a double-check, ensure the `Local Service` user has access to `C:\IronFoundry` and `C:\Ruby193`.

Installation from scratch:
------------------------------------------------------

* Ensure that `git` is installed and in your `PATH`

* Download a 32-bit Ruby 1.9.3 build from http://rubyinstaller.org/downloads/ and extract to `C:\Ruby193`. As of August 2013, Ruby 2.0+ wil not work.  This directory may be changed,
  but the examples in this document assume `ruby.exe` located at `C:\Ruby193\bin\ruby.exe`

* Add `C:\Ruby193\bin` to the system `PATH`

* Download a 32-bit Ruby Dev Kit from http://rubyinstaller.org/downloads/ and extract to `C:\RubyDevKit`. This directory may be changed, but the
  examples in this document assume this location. There is no need to add this to the `PATH`.

* Open a `cmd` window to initialize and validate dev kit installation and enable dev kit:

        C:\>cd \RubyDevKit
        
        C:\RubyDevKit>ruby dk.rb init
        [INFO] found RubyInstaller v1.9.3 at C:/Ruby193

        Initialization complete! Please review and modify the auto-generated
        'config.yml' file to ensure it contains the root directories to all
        of the installed Rubies you want enhanced by the DevKit.
        
        C:\RubyDevKit>ruby dk.rb review
        Based upon the settings in the 'config.yml' file generated
        from running 'ruby dk.rb init' and any of your customizations,
        DevKit functionality will be injected into the following Rubies
        when you run 'ruby dk.rb install'.
        
        C:/Ruby193
        
        C:\RubyDevKit>ruby dk.rb install
        [INFO] Updating convenience notice gem override for 'C:/Rubies/Ruby193'
        [INFO] Installing 'C:/Ruby193/lib/ruby/site_ruby/devkit.rb'

* Before updating and installing Ruby gems, you may want to create an ASCII text `.gemrc` file in your home directory
(`C:\Users\username\.gemrc`) with this content. It will save space and time by blocking installation of rdoc and ri files:

        install: --no-rdoc --no-ri
        update:  --no-rdoc --no-ri

* Update and install some gems:

        C:\>gem update --system
        C:\>gem install bundler

* Download [`curl-7.32.0-devel-mingw32.zip` curl development libraries](http://curl.haxx.se/dlwiz/?type=lib&os=Win32&flav=-) and extract to a
directory on your system - `C:\tmp` in this example. Then, use the following command to install the `patron` gem using this download:

        C:\>gem install patron -v '0.4.18' --platform=x86-mingw32 -- -- --with-curl-lib=C:\tmp\curl-7.32.0-devel-mingw32\bin --with-curl-include=C:\tmp\curl-7.32.0-devel-mingw32\include
        Fetching: patron-0.4.18.gem (100%)
        Temporarily enhancing PATH to include DevKit...
        Building native extensions with: '-- --with-curl-lib=C:\tmp\curl-7.31.0-devel-mingw32\bin --with-curl-include=C:\tmp\curl-7.31.0-devel-mingw32\include'
        This could take a while...
        Successfully installed patron-0.4.18
        1 gem installed

* Create the required directory structure using the following set of commands, which may be saved as a batch file.  The base path `C:\IronFoundry` can be changed but the examples in this document and the configuration paths in dea_mswin-clr.yml assume this location.

        mkdir C:\IronFoundry\buildpack_cache
        mkdir C:\IronFoundry\dea_ng\app
        mkdir C:\IronFoundry\dea_ng\crashes
        mkdir C:\IronFoundry\dea_ng\db
        mkdir C:\IronFoundry\dea_ng\droplets
        mkdir C:\IronFoundry\dea_ng\instances
        mkdir C:\IronFoundry\dea_ng\staging
        mkdir C:\IronFoundry\dea_ng\tmp
        mkdir C:\IronFoundry\log
        mkdir C:\IronFoundry\package_cache
        mkdir C:\IronFoundry\run
        mkdir C:\IronFoundry\warden\containers

* Check out the `dea_ng` source. Note that this command will switch to the reqired `ironfoundry` branch as well as initialize submodules:

        C:\tmp>cd \IronFoundry\dea_ng
        C:\IronFoundry\dea_ng>git clone --recursive https://github.com/cloudfoundry/dea_ng.git app

* Install required gems for `dea_ng` (extra output truncated):

        C:\IronFoundry\dea_ng>cd app
        C:\IronFoundry\dea_ng\app>bundle install

* You must install eventmachine from source. Clone the `eventmachine` source from the Iron Foundry organization and build from the `ironfoundry` branch (extra output truncated):

        C:\tmp>git clone --branch ironfoundry https://github.com/IronFoundry/eventmachine.git
        Cloning into 'eventmachine'...
        C:\tmp>cd eventmachine
        C:\tmp\eventmachine>gem uninstall eventmachine # Say 'Yes' to all versions here!
        C:\tmp\eventmachine>gem build eventmachine.gemspec
        C:\tmp\eventmachine>gem install eventmachine-1.0.3.gem

* Set up and build the Directory Server
    * Download and install [Go](http://golang.org) for Windows (64 bit) [downloaded here](https://code.google.com/p/go/downloads/list)
    * Set the GOPATH environment variable to C:\IronFoundry\dea_ng\app\go (In PowerShell: $env:GOPATH=$PWD if you are in the go directory)
    * Build the directory server

            C:\IronFoundry\dea_ng\app\go>go build .\src\winrunner

* Set up the Directory Server as a windows service and add some firewall rules (needs elevated privileges):

        C:\>C:\IronFoundry\dea_ng\app\go\winrunner install "C:\IronFoundry\dea_ng\app\config\dea_mswin-clr.yml"
        C:\>netsh advfirewall firewall add rule name=runner-Allow dir=in action=allow program=C:\IronFoundry\dea_ng\app\go\winrunner.exe
        C:\>netsh advfirewall firewall add rule name=runner-out-Allow dir=out action=allow program=C:\IronFoundry\dea_ng\app\go\winrunner.exe

* Set up the DEA as a windows service and add some firewall rules (needs elevated privileges):

        C:\>sc.exe create IFDeaSvc start= delayed-auto binPath= "C:\Ruby193\bin\rubyw.exe -C C:\IronFoundry\dea_ng\app\bin dea_winsvc.rb C:\IronFoundry\dea_ng\app\config\dea_mswin-clr.yml" DisplayName= "Iron Foundry DEA"
        C:\>sc.exe failure IFDeaSvc reset= 86400 actions= restart/600000/restart/600000/restart/600000
        C:\>netsh advfirewall firewall add rule name=rubyw-193-Allow dir=in action=allow program=C:\Ruby193\bin\rubyw.exe
        C:\>netsh advfirewall firewall add rule name=rubyw-193-out-allow dir=out action=allow program=C:\Ruby193\bin\rubyw.exe

* Edit these sections in the DEA `C:\IronFoundry\dea_ng\app\config\dea_mswin-clr.yml` file:

        logging:
          level: error # set to "debug2" to see all messages
          file: C:/IronFoundry/log/dea_ng.log

		 loggregator:
		    router: 172.21.101.28:3456 # set to your cloud controller IP

        domain: vcap.me # set to your domain

        nats_uri: # set to 'nats://NATS_IP:4222' or 'nats://USER:PASSWORD@NATS_IP:4222'

* Start up the DEA:

        C:\>sc start IFDeaSvc
