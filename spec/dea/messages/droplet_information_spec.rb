# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  it "should reply to messages on 'droplet.status' with all live droplets" do
    # Register one instance per state
    instances = {}
    Dea::Instance::State.constants.each do |state|
      name = state.to_s
      instance = Dea::Instance.new(bootstrap,
                                     "application_name" => name,
                                     "application_uris" => ["http://www.foo.bar/#{name}"])
      instance.state = Dea::Instance::State.const_get(state)
      bootstrap.instance_registry.register(instance)
      instances[instance.application_name] = instance
    end

    responses = []
    nats_mock.subscribe("results") do |msg, _|
      responses << Yajl::Parser.parse(msg)
    end

    nats_mock.publish("droplet.status", {}, "results")

    responses.size.should == 2
    responses.each do |r|
      ["RUNNING", "STARTING"].include?(r["name"]).should be_true
      r["uris"].should == instances[r["name"]].application_uris
    end
  end

  describe "responses to messages received on 'dea.find.droplet'" do
    before :each do
      @instances = []

      [Dea::Instance::State::RUNNING,
       Dea::Instance::State::STOPPED,
       Dea::Instance::State::STARTING].each_with_index do |state, ii|
        instance = Dea::Instance.new(bootstrap,
                                     "application_id"      => (ii == 0) ? 0 : 1,
                                     "application_version" => ii,
                                     "instance_index"      => ii,
                                     "application_uris"    => ["foo", "bar"])
        instance.state = state
        @instances << instance
        bootstrap.instance_registry.register(instance)
      end
    end

        it "should respond with a correctly formatted message" do
      responses = find_droplet(@nats_mock,
                               { "droplet" => @instances[0].application_id })
      expected = {
        "dea"      => bootstrap.uuid,
        "droplet"  => @instances[0].application_id,
        "version"  => @instances[0].application_version,
        "instance" => @instances[0].instance_id,
        "index"    => @instances[0].instance_index,
        "state"    => @instances[0].state,
        "state_timestamp" => @instances[0].state_timestamp,
      }

      responses.size.should == 1
      responses[0].should include(expected)
    end

    it "should include 'stats' if requested" do
      responses = find_droplet(@nats_mock,
                               { "droplet" => @instances[0].application_id,
                                 "include_stats" => true})
      expected = {
        "name" => @instances[0].application_name,
        "uris" => @instances[0].application_uris,
      }

      responses.size.should == 1
      responses[0]["stats"].should == expected
    end

    it "should support filtering by application version" do
      responses = find_droplet(@nats_mock,
                               { "droplet" => @instances[1].application_id,
                                 "version" => @instances[1].application_version})

      responses.size.should == 1
      responses[0]["instance"].should == @instances[1].instance_id
    end

    it "should support filtering by instance index" do
      responses = find_droplet(@nats_mock,
                               { "droplet" => @instances[1].application_id,
                                 "indices" => [@instances[2].instance_index]})

      responses.size.should == 1
      responses[0]["instance"].should == @instances[2].instance_id
    end

    it "should support filtering by state" do
      responses = find_droplet(@nats_mock,
                               { "droplet" => @instances[1].application_id,
                                 "states" => [@instances[2].state]})

      responses.size.should == 1
      responses[0]["instance"].should == @instances[2].instance_id
    end

    it "should support filtering with multiple values" do
      filters = %w[indices instances states]
      getters = %w[instance_index instance_id state].map(&:to_sym)

      filters.zip(getters).each do |filter, getter|
        request = {
          "droplet" => @instances[1].application_id,
          filter    => @instances.slice(1, 2).map(&getter)
        }

        responses = find_droplet(@nats_mock, request)

        responses.size.should == 2
        ids = responses.map { |r| r["instance"] }
        ids.include?(@instances[1].instance_id).should be_true
        ids.include?(@instances[2].instance_id).should be_true
      end
    end

    def find_droplet(nats_mock, request)
      responses = []
      nats_mock.subscribe("results") do |msg, _|
        responses << Yajl::Parser.parse(msg)
      end

      nats_mock.publish("dea.find.droplet", request, "results")

      responses
    end
  end
end
