# coding: UTF-8

require "spec_helper"
require "dea/nats"

describe Dea::Nats do
  before do
    @config = {
      :nats_uri => "nats://something:4222",
    }
  end

  before do
    NATS.stub(:connect) do |options|
      @nats_client = NatsClientMock.new(options)
    end
  end

  attr_reader :nats_client

  let(:bootstrap) do
    mock("bootstrap")
  end

  subject(:nats) do
    Dea::Nats.new(bootstrap, @config)
  end

  describe "subscription setup" do
    before do
      @config[:uuid] = "UUID"
    end

    before do
      nats.start
    end

    {
      "healthmanager.start" => :handle_health_manager_start,
      "router.start"        => :handle_router_start,
      "dea.status"          => :handle_dea_status,
      "dea.UUID.start"      => :handle_dea_directed_start,
      "dea.locate"          => :handle_dea_locate,
      "dea.stop"            => :handle_dea_stop,
      "dea.update"          => :handle_dea_update,
      "dea.find.droplet"    => :handle_dea_find_droplet,
      "droplet.status"      => :handle_droplet_status,
    }.each do |subject, method|
      it "should subscribe to #{subject.inspect}" do
        data = { "subject" => subject }

        bootstrap.should_receive(method).with(kind_of(Dea::Nats::Message)) do |message|
          message.subject.should == subject
          message.data.should == data
        end

        nats_client.receive_message(subject, data)
      end
    end
  end
end
