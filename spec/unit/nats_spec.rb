# coding: UTF-8

require "spec_helper"
require "dea/nats"

describe Dea::Nats do
  stub_nats

  let(:bootstrap) { double("bootstrap") }
  let(:config) { {"nats_servers" => ["nats://user:password@something:4222"]} }
  subject(:nats) { Dea::Nats.new(bootstrap, config) }

  describe "subscription setup" do
    before { allow(bootstrap).to receive(:uuid).and_return("UUID") }
    before { nats.start }

    {
      "dea.stop"            => :handle_dea_stop,
      "dea.update"          => :handle_dea_update,
      "dea.find.droplet"    => :handle_dea_find_droplet
    }.each do |subject, method|
      it "should subscribe to #{subject.inspect}" do
        data = { "subject" => subject }

        expect(bootstrap).to receive(method).with(kind_of(Dea::Nats::Message)) do |message|
          expect(message.subject).to eq(subject)
          expect(message.data).to eq(data)
        end

        nats_mock.receive_message(subject, data)
      end
    end

    it 'subscribes to dea.UUID.start' do
      data = { "subject" => 'dea.UUID.start' }
      expect(bootstrap).to receive(:start_app).with(data)

      nats_mock.receive_message('dea.UUID.start', data)
    end

    it "subscribes to router.start" do
      expect(bootstrap).to receive(:handle_router_start)
      nats_mock.receive_message("router.start", "")
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
      expect(log_record).to include "nats://something:4222"
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
      nats.sids.each { |_, sid| expect(nats_mock).to receive(:unsubscribe).with(sid) }

      nats.stop
    end
  end

  describe "message" do
    it "should be able to respond" do
      nats.subscribe("echo") do |message|
        message.respond(message.data)
      end

      expect(nats_mock).to receive(:publish).with("echo.reply", %{{"hello":"world"}})
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

    it 'can respond to a message and call a callback' do
      called = false

      nats.subscribe("echo") do |message|
        message.respond(message.data) do
          called = true
        end
      end

      nats_mock.receive_message("echo", { "hello" => "world" }, "echo.reply")
      expect(called).to be true
    end
  end

  describe "#subscribe" do
    it "returns subscription id" do
      sids = [nats.subscribe("subject-2"), nats.subscribe("subject-1")]
      expect(sids.uniq).to eq(sids)
    end

    it "does not unsubscribe if subscribed with do-not-track-subscription option" do
      nats.subscribe("subject-1", :do_not_track_subscription => true)
      expect(nats_mock).to_not receive(:unsubscribe)
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
