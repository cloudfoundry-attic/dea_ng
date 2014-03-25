Vagrant.configure("2") do |config|
  # Build this box by running `rake test_vm`
  config.vm.box = "warden-compatible"
  config.vm.box_url = "~/boxes/warden-compatible.box"
  config.ssh.username = "vagrant"
  config.vm.define "dea_test_vm"
end
