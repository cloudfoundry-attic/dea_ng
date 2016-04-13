require 'uuidtools'
require 'socket'

module Dea
  def self.local_ip(route = '1.2.3.4')
      orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true
      @local_ip = UDPSocket.open {|s| s.connect(route, 1); s.addr.last }
    ensure
      Socket.do_not_reverse_lookup = orig
  end

  def self.grab_ephemeral_port
    orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true
    socket = TCPServer.new('0.0.0.0', 0)
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
    port = socket.addr[1]
    socket.close
    return port
  ensure
    Socket.do_not_reverse_lookup = orig
  end

  def self.secure_uuid
    UUIDTools::UUID.random_create.to_s.delete('-')
  end
end
