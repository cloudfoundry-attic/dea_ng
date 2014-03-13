<!---
  vim:sw=2:ts=2:expandtab:fo=t:tw=144
-->

Installing the DEA on Windows
=============================

It is recommended to use the [installation package](#installation-package) to install the V2 DEA on Windows.

Be sure to update your Cloud Controller's `config/stacks.yml` to recognize the `mswin-clr` stack:

```
$ cat cloud_controller_ng/config/stacks.yml 
default: lucid64

stacks:
  - name: lucid64
    description: Ubuntu Lucid 64-bit
  - name: mswin-clr
    description: Microsoft .NET / Windows 64-bit
```

Installation package:
-------------------------------------------------

Installation scripts are available in the [if_release](https://github.com/IronFoundry/if_release) repository.  This repository is similar to the cf_release repository for Cloud Foundry V2.
