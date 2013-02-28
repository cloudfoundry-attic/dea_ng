Vagrant::Config.run do |config|
  config.vm.box = "precise64"
  config.vm.box_url = "http://files.vagrantup.com/precise64.box"

  config.vm.forward_port 4222, 4222
  config.vm.forward_port 5678, 5678

  config.vm.share_folder "dea_repo", "/dea", "."

  config.vm.provision :chef_solo do |chef|
    chef.cookbooks_path = ["./chef/cookbooks", "./chef"]
    chef.log_level = :debug
    chef.add_recipe "apt"
    chef.add_recipe "git"
    chef.add_recipe "dea::packages"
    chef.add_recipe "dea::warden"
    chef.add_recipe "dea::dea"

    chef.json = {}
  end
end
