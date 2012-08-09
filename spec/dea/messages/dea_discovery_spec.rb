# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  it "should publish a message on 'vcap.component.announce' on startup" do
    announcement = nil
    nats_mock.subscribe("vcap.component.announce") do |msg|
      announcement = Yajl::Parser.parse(msg)

      EM.stop
    end

    em(:timeout => 1) do
      bootstrap.start
    end

    announcement.should_not be_nil
  end

  it "should publish a message on 'dea.start' on startup" do
    hello = nil
    nats_mock.subscribe("dea.start") do |msg|
      hello = Yajl::Parser.parse(msg)
      EM.stop
    end

    em(:timeout => 1) do
      bootstrap.start
    end

    verify_hello_message(bootstrap, hello)
  end

  it "should respond to messages on 'dea.status' with enhanced hello messages" do
    status = nil
    nats_mock.subscribe("results") do |msg|
      status = Yajl::Parser.parse(msg)
      EM.stop
    end

    em(:timeout => 1) do
      bootstrap.start

      nats_mock.publish("dea.status", {}, "results")
    end

    verify_status_message(bootstrap, status)
  end

  describe "dea.discover" do
    it "should not respond for unsupported runtimes" do
      recvd_msg = false

      msg = discover_message("runtime" => "unsupported")
      nats_mock.request("dea.discover", msg) { |_| recvd_msg = true }

      recvd_msg.should be_false
    end

    it "should not respond if insufficient resources" do
      bootstrap.resource_manager.stub(:could_reserve?).and_return(false)

      recvd_msg = false
      nats_mock.request("dea.discover", discover_message) { |_| recvd_msg = true }

      recvd_msg.should be_false
    end

    it "should respond with a hello message given sufficient resources" do
      hello = nil

      em(:timeout => 1) do
        disc_msg = discover_message("droplet" => 1)
        nats_mock.request("dea.discover", disc_msg) do |msg|
          hello = Yajl::Parser.parse(msg)
          EM.stop
        end
      end

      verify_hello_message(bootstrap, hello)
    end

    it "should delay its response proportionally to the number of instances already running" do
      2.times do
        create_and_register_instance(bootstrap, "application_id" => 0)
      end

      hello = nil
      tstart = Time.now

      em(:timeout => 1) do
        disc_msg = discover_message("droplet" => 0)
        nats_mock.request("dea.discover", disc_msg) do |msg|
          hello = Yajl::Parser.parse(msg)
          EM.stop
        end
      end

      elapsed = Time.now - tstart

      expected_delay = (2.0 * Dea::Bootstrap::DISCOVER_DELAY_MS_PER_INSTANCE) / 1000

      verify_hello_message(bootstrap, hello)
      elapsed.should be_within(0.05).of(expected_delay)
    end

    it "should delay its response proportionally to the amount of memory available" do
      mem_mock = mock("memory")
      mem_mock.stub(:used).and_return(1)
      mem_mock.stub(:capacity).and_return(2)
      resources = { "memory" => mem_mock }
      bootstrap.resource_manager.stub(:resources).and_return(resources)

      hello = nil
      tstart = Time.now

      em(:timeout => 1) do
        disc_msg = discover_message("droplet" => 0)
        nats_mock.request("dea.discover", disc_msg) do |msg|
          hello = Yajl::Parser.parse(msg)
          EM.stop
        end
      end

      elapsed = Time.now - tstart

      expected_delay = (0.5 * Dea::Bootstrap::DISCOVER_DELAY_MS_MEM) / 1000

      verify_hello_message(bootstrap, hello)
      elapsed.should be_within(0.05).of(expected_delay)
    end

    it "should cap its delay at a maximum" do
      ninstances_needed =
        Dea::Bootstrap::DISCOVER_DELAY_MS_MAX / Dea::Bootstrap::DISCOVER_DELAY_MS_PER_INSTANCE

      instances = (0..(ninstances_needed + 1)).to_a
      bootstrap.instance_registry                \
               .stub(:instances_for_application) \
               .and_return(instances)

      hello = nil
      tstart = Time.now

      em(:timeout => 1) do
        disc_msg = discover_message("droplet" => 0)
        nats_mock.request("dea.discover", disc_msg) do |msg|
          hello = Yajl::Parser.parse(msg)
          EM.stop
        end
      end

      elapsed = Time.now - tstart

      expected_delay = (Dea::Bootstrap::DISCOVER_DELAY_MS_MAX.to_f / 1000)

      verify_hello_message(bootstrap, hello)
      elapsed.should be_within(0.05).of(expected_delay)
    end
  end

  def discover_message(opts = {})
    { "runtime" => "test1",
      "droplet" => 0,
      "limits"  => {
        "mem"  => 10,
        "disk" => 10,
      }
    }.merge(opts)
  end

  def verify_hello_message(bootstrap, hello)
    hello.should_not be_nil
    hello["id"].should == bootstrap.uuid
    hello["ip"].should == bootstrap.local_ip
    hello["port"].should == bootstrap.directory_server.port
    hello["version"].should == Dea::VERSION
  end

  def verify_status_message(bootstrap, status)
    verify_hello_message(bootstrap, status)

    %W[max_memory reserved_memory used_memory num_clients].each do |k|
      status.has_key?(k).should be_true
    end
  end
end

