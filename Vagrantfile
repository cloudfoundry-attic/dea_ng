Vagrant::Config.run do |config|
  config.vm.box = "precise64"
  config.vm.box_url = "http://files.vagrantup.com/precise64.box"

  config.vm.forward_port 4222, 4222 # NATS
  config.vm.forward_port 5678, 5678 # DirectoryServerV2
  config.vm.forward_port 8001, 8001 # Logplex REST

  config.vm.share_folder "dea_repo", "/dea", "."

  config.vm.provision :chef_solo do |chef|
    chef.cookbooks_path = ["./chef/cookbooks", "./chef"]
    chef.provisioning_path = "/var/vagrant-chef"
    chef.log_level = :debug

    chef.add_recipe "apt"
    chef.add_recipe "git"
    chef.add_recipe "erlang"
    chef.add_recipe "dea::packages"
    chef.add_recipe "dea::dea"
    chef.add_recipe "warden::install"
    chef.add_recipe "warden::customize_rootfs"

    chef.json = {
      erlang: {
        install_method: :source,
        source: {
          url: "http://erlang.org/download/otp_src_R15B03-1.tar.gz",
          version: "R15B03",
          checksum: "1d7ace92e8cf41abbee1dba8192b7d5f"
        }
      }
    }
  end
end
