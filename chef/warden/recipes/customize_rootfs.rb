ROOT_FS = "/var/warden/rootfs"
RUBY_BUILD_DIR = "tmp/ruby-build"
PREFIX = "/usr/local"
RUBY_VERSION = "1.9.3-p392"

git "#{ROOT_FS}/#{RUBY_BUILD_DIR}" do
  repository "git://github.com/sstephenson/ruby-build.git"
  reference "master"
  action :sync
end

execute_in_chroot "install packages" do
  root_dir ROOT_FS
  command "apt-get --yes install zlib1g-dev unzip curl"
  creates "#{ROOT_FS}/#{PREFIX}/usr/bin/curl"
end

execute_in_chroot "install ruby" do
  root_dir ROOT_FS
  command [
    "cd #{RUBY_BUILD_DIR}",
    "PREFIX=#{PREFIX} ./install.sh",
    "#{PREFIX}/bin/ruby-build #{RUBY_VERSION} #{PREFIX}/ruby"
  ].join(' && ')
  creates "#{ROOT_FS}/#{PREFIX}/ruby/bin/ruby"
end
