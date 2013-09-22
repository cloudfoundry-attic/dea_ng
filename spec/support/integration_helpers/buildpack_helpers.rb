require "socket"

module BuildpackHelpers
  def file_server_address
    ips = Socket.ip_address_list

    ips.select!(&:ipv4?)

    # skip 127.0.0.1
    ips.reject!(&:ipv4_loopback?)

    # this conflicts with the bosh-lite networking
    ips.reject! { |ip| ip.ip_address.start_with?("192.168.50.") }

    local_ip = ips.first
    raise "Cannot determine an IP reachable from the VM." unless local_ip

    "#{local_ip.ip_address}:9999"
  end

  def fake_buildpack_url(buildpack_name)
    "http://#{file_server_address}/buildpacks/#{buildpack_name}/.git"
  end

  def setup_fake_buildpack(buildpack_name)
    Dir.chdir("spec/fixtures/fake_buildpacks/#{buildpack_name}") do
      `rm -rf .git`
      `git init`
      `git add . && git add -A`
      `git commit -am "fake commit"`
      `git update-server-info`
    end
  end

  def download_tgz(url)
    Dir.mktmpdir do |dir|
      `curl --silent --show-error #{url} > #{dir}/staged_app.tgz`
      `cd #{dir} && tar xzf staged_app.tgz`
      yield dir
    end
  end
end
