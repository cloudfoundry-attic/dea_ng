class LocalIPFinder
  def find
    ips = Socket.ip_address_list

    ips.select!(&:ipv4?)

    # skip 127.0.0.1
    ips.reject!(&:ipv4_loopback?)

    # this conflicts with the bosh-lite networking
    ips.reject! { |ip| ip.ip_address.start_with?("192.168.50.") }
    ips.reject! { |ip| ip.ip_address.start_with?("10.253.") }

    local_ip = ips.first
    raise "Cannot determine an IP reachable from the VM." unless local_ip
    return local_ip
  end
end
