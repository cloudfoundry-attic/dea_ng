desc "Install/run directory server"
namespace :dir_server do

  desc "Run log_server/n directory server"
  task :run => [:install] do
    system "go/bin/runner -conf config/dea.yml"
  end

  desc "Install directory server"
  task :install do
    result = nil
    Dir.chdir("go") do
      result = system "GOPATH=$PWD PATH=$PATH:/usr/local/go/bin go install runner"
    end

    raise "Installation failed" unless result
  end
end
