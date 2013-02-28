git "/warden" do
  repository "git://github.com/cloudfoundry/warden.git"
  reference "master"
  action :sync
end

execute "setup_warden" do
  cwd "/warden/warden"
  command "bundle install && bundle exec rake setup[config/linux.yml] && touch /warden/warden/install_succeeded"
  creates "/warden/warden/install_succeeded"
  action :run
  not_if do
    File.exists?("/warden/warden/install_succeeded")
  end
end