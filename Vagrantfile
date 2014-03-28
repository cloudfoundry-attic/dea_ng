Vagrant.configure("2") do |config|
  # Build this box by running `rake test_vm`
  config.vm.box = "warden-compatible"
  config.vm.box_url = "https://s3.amazonaws.com/runtime-artifacts/warden-compatible.box"
  config.ssh.username = "vagrant"

  config.vm.provision "shell", inline: "sudo apt-get -q -y install libxslt-dev libxml2-dev" # For Nokogiri
  config.vm.provision "shell", inline: "sudo apt-get -q -y install libcurl4-gnutls-dev" # For
end
