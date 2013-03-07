git "/warden" do
  repository "git://github.com/cloudfoundry/warden.git"
  reference "master"
  action :sync
end

execute "setup_warden" do
  cwd "/warden/warden"
  command "bundle install && bundle exec rake setup[config/linux.yml]"
  creates "/tmp/warden/rootfs"
  action :run
end