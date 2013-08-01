# coding: UTF-8

require "spec_helper"
require "dea/nats"

describe Dea::Nats do
  stub_nats

  let(:bootstrap) { mock("bootstrap") }
  let(:config) { {"nats_uri" => "nats://something:4222"} }
  subject(:nats) { Dea::Nats.new(bootstrap, config) }

  describe "subscription setup" do
    before { bootstrap.stub(:uuid).and_return("UUID") }
    before { nats.start }

    {
      "healthmanager.start" => :handle_health_manager_start,
      "router.start"        => :handle_router_start,
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

      nats.subscribe("some.subject") do |message|
        raise "This should not be called"
      end

      nats_mock.receive_message("some.subject", "{\"foo\": oops an error in the json", "echo.reply")

      logfile.rewind
      Yajl::Parser.parse(logfile.readlines[1])["message"].should =~ /^Parse error/
    end

    it "ignores rspec errors" do
      logfile = Tempfile.open("dea_nats")
      Steno.init(Steno::Config.new({:sinks => [Steno::Sink::IO.new(logfile)]}))

      nats.subscribe("some.subject") do |message|
        "this should fail".should be_nil
      end

      exception =
        begin
          expect {
            nats_mock.receive_message("some.subject", {"foo" => "bar"}, "echo.reply")
          }.to_not change(logfile.readlines, :size)
        rescue => e
          e
        end

      exception.should be_kind_of(RSpec::Expectations::ExpectationNotMetError)
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
  end
end
