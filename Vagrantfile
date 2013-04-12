Vagrant.configure("2") do |config|
  config.vm.box = "ci_with_warden_prereqs"
  config.vm.box_url = "~/boxes/ci_with_warden_prereqs.box"
  config.ssh.username = "travis"
  config.vm.define "dea_test_vm"
end
