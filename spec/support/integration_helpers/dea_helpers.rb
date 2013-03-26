module DeaHelpers
  def dea_id
    nats.request("dea.discover", {
      "limits" => { "mem" => 1, "disk" => 1 }
    })["id"]
  end

  def dea_memory
    response = nats.with_subscription("dea.advertise") do
      nats.publish("dea.locate", {}, :async => true)
    end

    response["available_memory"]
  end

  private

  def nats
    NatsHelper.new
  end
end