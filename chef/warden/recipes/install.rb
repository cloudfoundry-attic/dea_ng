WARDEN_PATH = "/warden"
ROOTFS_PATH = "/var/warden/rootfs"
OLD_CONFIG_FILE_PATH = "#{WARDEN_PATH}/warden/config/linux.yml"
NEW_CONFIG_FILE_PATH = "#{WARDEN_PATH}/warden/config/dea_vm.yml"

git WARDEN_PATH do
  repository "git://github.com/cloudfoundry/warden.git"
  reference "master"
  action :sync
end

ruby_block "configure warden to put its rootfs outside of /tmp" do
  block do
    require "yaml"
    config = YAML.load_file(OLD_CONFIG_FILE_PATH)
    config["server"]["container_rootfs_path"] = ROOTFS_PATH
    File.open(NEW_CONFIG_FILE_PATH, 'w') { |f| YAML.dump(config, f) }
  end
  action :create
end

execute "setup_warden" do
  cwd "#{WARDEN_PATH}/warden"
  command "bundle install && bundle exec rake setup[#{NEW_CONFIG_FILE_PATH}]"
  creates ROOTFS_PATH
  action :run
end
