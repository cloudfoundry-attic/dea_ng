# coding: UTF-8

require "spec_helper"
require "dea/nats"

describe Dea::Nats do
  stub_nats

  let(:bootstrap) { double("bootstrap") }
  let(:config) { {"nats_servers" => ["nats://user:password@something:4222"]} }
  subject(:nats) { Dea::Nats.new(bootstrap, config) }

  describe "subscription setup" do
    before { bootstrap.stub(:uuid).and_return("UUID") }
    before { nats.start }

    {
      "healthmanager.start" => :handle_health_manager_start,
      "dea.status"          => :handle_dea_status,
      "dea.UUID.start"      => :handle_dea_directed_start,
      "dea.stop"            => :handle_dea_stop,
      "dea.update"          => :handle_dea_update,
      "dea.find.droplet"    => :handle_dea_find_droplet
    }.each do |subject, method|
      it "should subscribe to #{subject.inspect}" do
        data = { "subject" => subject }

        bootstrap.should_receive(method).with(kind_of(Dea::Nats::Message)) do |message|
          message.subject.should == subject
          message.data.should == data
        end

        nats_mock.receive_message(subject, data)
      end
    end

    it "subscribes to router.start" do
      allow(bootstrap).to receive(:handle_router_start)
      nats_mock.receive_message("router.start", "")
      expect(bootstrap).to have_received(:handle_router_start)
    end
  end

  describe "create_nats_client" do
    let (:logfile) { Tempfile.open("dea_nats") }

    before do
      Steno.init(Steno::Config.new({:sinks => [Steno::Sink::IO.new(logfile)]}))
      nats.create_nats_client
      logfile.rewind
    end

    it "does not log nats credentials" do
      log_record = logfile.readlines[0]
      expect(log_record).to_not include "nats://user:password@something:4222"
      expect(log_record).to include "nats://user@something:4222"
    end
  end

  describe "flush" do
    it "delegates to the client" do
      expected_block = -> {}
      expect(nats_mock).to receive(:flush) do |&block|
        expect(block).to eq(expected_block)
      end

      nats.flush(&expected_block)
    end
  end

  describe "subscription teardown" do
    it "should unsubscribe from everything when stop is called" do
      nats.sids.each { |_, sid| nats_mock.should_receive(:unsubscribe).with(sid) }

      nats.stop
    end
  end

  describe "message" do
    it "should be able to respond" do
      nats.subscribe("echo") do |message|
        message.respond(message.data)
      end

      nats_mock.should_receive(:publish).with("echo.reply", %{{"hello":"world"}})
      nats_mock.receive_message("echo", { "hello" => "world" }, "echo.reply")
    end

    it "catches invalid Json errors and logs them while processing a message" do
      logfile = Tempfile.open("dea_nats")
      Steno.init(Steno::Config.new({:sinks => [Steno::Sink::IO.new(logfile)]}))

      nats.subscribe("some.subject") {}

      nats_mock.receive_message("some.subject", "{\"foo\": oops an error in the json", "echo.reply")

      logfile.rewind
      expect(logfile.readlines[1]).to include "nats.subscription.json_error"
    end
  end

  describe "#subscribe" do
    it "returns subscription id" do
      sids = [nats.subscribe("subject-2"), nats.subscribe("subject-1")]
      sids.uniq.should == sids
    end

    it "does not unsubscribe if subscribed with do-not-track-subscription option" do
      nats.subscribe("subject-1", :do_not_track_subscription => true)
      nats_mock.should_not_receive(:unsubscribe)
      nats.stop
    end

    context "when an error occurs" do
      it "should catch all json parsing errors" do
        expect {
          nats.subscribe("subject-1", :do_not_track_subscription => true)
          nats_mock.publish("subject-1", "}{")
        }.to_not raise_error
      end

      it "should catch all other errors since this is the top level" do
        expect {
          nats.subscribe("subject-1", :do_not_track_subscription => true) do
            raise RuntimeError, "Something Terrible"
          end
          nats_mock.publish("subject-1", '{"real_json": 1}')
        }.to_not raise_error
      end
    end
  end
end
