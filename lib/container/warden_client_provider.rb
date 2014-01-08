require "em/warden/client"

class WardenClientProvider
  attr_reader :socket_path

  def initialize(socket_path)
    @socket_path = socket_path
    @clients = {}
  end

  def get(name)
    client = @clients[name]

    return client if client && client.connected?
    new_client = EventMachine::Warden::FiberAwareClient.new(@socket_path)
    new_client.connect
    @clients[name] = new_client
    new_client
  end

  def close_all
    @clients.values.each(&:disconnect)
  end
end