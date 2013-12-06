require "spec_helper"

require "dea/router_client"

class FakeNats
  attr_reader :last_topic
  attr_reader :last_message

  def publish(topic, message)
    @last_topic = topic
    @last_message = message
  end

  def request(topic, &block)
    @last_topic = topic
    block.call
  end
end

describe Dea::RouterClient do
  let(:nats) { FakeNats.new }
  let(:config) { { "index" => 5 } }
  let(:uuid) { "dea-efd-123" }
  let(:local_ip) { "127.0.0.7" }
  let(:bootstrap) do
    double("Bootstrap",
      nats: nats,
      config: config,
      uuid: uuid,
      local_ip: local_ip,
    )
  end
  let(:client) { described_class.new(bootstrap) }

  let(:port) { 1234 }
  let(:uri) { "guid234.cf-apps.io" }
  let(:application_id) { "5678" }
  let(:instance_host_port) { "7890" }
  let(:private_instance_id) { "instance-id-123" }
  let(:application_uri) { "my-super-app.cf-app.com" }
  let(:instance) do
    double("instance",
      :application_id => application_id,
      :instance_host_port => instance_host_port,
      :private_instance_id => private_instance_id,
      :application_uris => [application_uri]
    )
  end

  describe "#register_directory_server" do
    it "sends a correct nats message" do
      client.register_directory_server(port, uri)

      expect(nats.last_topic).to eq("router.register")
      message = nats.last_message

      expect(message["host"]).to eq(local_ip)
      expect(message["port"]).to eq(port)
      expect(message["uris"]).to eq([uri])
      expect(message["tags"]).to eq({ "component" => "directory-server-5" })
    end
  end

  describe "#unregister_directory_server" do
    it "sends a correct nats message" do
      client.unregister_directory_server(port, uri)

      expect(nats.last_topic).to eq("router.unregister")
      message = nats.last_message

      expect(message["host"]).to eq(local_ip)
      expect(message["port"]).to eq(port)
      expect(message["uris"]).to eq([uri])
      expect(message["tags"]).to eq({ "component" => "directory-server-5" })
    end
  end

  describe "#register_instance" do
    it "sends a correct nats message" do
      client.register_instance(instance, :uris => [uri])

      expect(nats.last_topic).to eq("router.register")
      message = nats.last_message

      expect(message["dea"]).to eq(uuid)
      expect(message["app"]).to eq(application_id)
      expect(message["uris"]).to eq([uri])
      expect(message["host"]).to eq(local_ip)
      expect(message["port"]).to eq(instance_host_port)
      expect(message["tags"]).to eq({ "component" => "dea-5" })
      expect(message["private_instance_id"]).to eq(private_instance_id)
    end

    context "when uri is not passed" do
      it "uses application uri" do
        client.register_instance(instance)

        expect(nats.last_topic).to eq("router.register")
        message = nats.last_message

        expect(message["uris"]).to eq([application_uri])
      end
    end
  end

  describe "#unregister_instance" do
    it "sends a correct nats message" do
      client.unregister_instance(instance, :uris => [uri])

      expect(nats.last_topic).to eq("router.unregister")
      message = nats.last_message

      expect(message["dea"]).to eq(uuid)
      expect(message["app"]).to eq(application_id)
      expect(message["uris"]).to eq([uri])
      expect(message["host"]).to eq(local_ip)
      expect(message["port"]).to eq(instance_host_port)
      expect(message["tags"]).to eq({ "component" => "dea-5" })
      expect(message["private_instance_id"]).to eq(private_instance_id)
    end

    context "when uri is not passed" do
      it "uses application uri" do
        client.unregister_instance(instance)

        expect(nats.last_topic).to eq("router.unregister")
        message = nats.last_message

        expect(message["uris"]).to eq([application_uri])
      end
    end
  end

  describe "#greet" do
    it "sends greet message" do
      block_called = false
      client.greet do
        block_called = true
      end
      expect(nats.last_topic).to eq("router.greet")
      expect(block_called).to eq(true)
    end
  end
end