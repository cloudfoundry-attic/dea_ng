execute "install dea gems" do
  cwd "/dea"
  command "bundle install"
  action :run
end