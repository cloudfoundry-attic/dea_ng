# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  before do
    bootstrap.unstub(:setup_directory_server)
  end

  it "should publish a message on 'vcap.component.announce' on startup" do
    bootstrap.unstub(:start_component)

    announcement = nil
    nats_mock.subscribe("vcap.component.announce") do |msg|
      announcement = Yajl::Parser.parse(msg)
      done
    end

    em(:timeout => 1) do
      bootstrap.setup
      bootstrap.start
    end

    announcement.should_not be_nil
  end

  it "should publish a message on 'dea.start' on startup" do
    bootstrap.unstub(:start_finish)

    start = nil
    nats_mock.subscribe("dea.start") do |msg|
      start = Yajl::Parser.parse(msg)
      done
    end

    em(:timeout => 1) do
      bootstrap.setup
      bootstrap.start
    end

    verify_hello_message(bootstrap, start)
  end

  it "should respond to messages on 'dea.status' with enhanced hello messages" do
    status = nil
    nats_mock.subscribe("result") do |msg|
      status = Yajl::Parser.parse(msg)
      done
    end

    em(:timeout => 1) do
      bootstrap.setup
      bootstrap.start

      nats_mock.publish("dea.status", {}, "result")
    end

    verify_status_message(bootstrap, status)
  end

  describe "dea.discover" do
    it "should support any runtime" do
      received_message = nil

      em(:timeout => 1) do
        bootstrap.setup
        bootstrap.start

        req = discover_message("runtime" => "anything")
        nats_mock.request("dea.discover", req) do |msg|
          received_message = Yajl::Parser.parse(msg)
          done
        end
      end

      verify_hello_message(bootstrap, received_message)
    end

    it "should not respond if insufficient resources" do
      received_message = false

      em(:timeout => 1) do
        bootstrap.setup
        bootstrap.start

        bootstrap.resource_manager.stub(:could_reserve?).and_return(false)

        req = discover_message()
        nats_mock.request("dea.discover", req) do
          received_message = true
        end

        done
      end

      received_message.should be_false
    end

    it "should respond with a hello message given sufficient resources" do
      hello = nil

      em(:timeout => 1) do
        bootstrap.setup
        bootstrap.start

        req = discover_message("droplet" => 1)
        nats_mock.request("dea.discover", req) do |msg|
          hello = Yajl::Parser.parse(msg)
          done
        end
      end

      verify_hello_message(bootstrap, hello)
    end

    it "should delay its response proportionally to the number of instances already running" do
      hello = nil
      start = Time.now

      em(:timeout => 1) do
        bootstrap.setup
        bootstrap.start

        bootstrap.resource_manager.stub(:used_memory).and_return(0)
        bootstrap.resource_manager.stub(:memory_capacity).and_return(200)

        2.times do
          create_and_register_instance(bootstrap, "application_id" => 0)
        end

        req = discover_message("droplet" => 0)
        nats_mock.request("dea.discover", req) do |msg|
          hello = Yajl::Parser.parse(msg)
          done
        end
      end

      actual_delay = Time.now - start
      expected_delay = (2.0 * Dea::Bootstrap::DISCOVER_DELAY_MS_PER_INSTANCE) / 1000

      verify_hello_message(bootstrap, hello)
      actual_delay.should be_within(0.05).of(expected_delay)
    end

    it "should delay its response proportionally to the amount of memory available" do
      hello = nil
      start = Time.now

      em(:timeout => 1) do
        bootstrap.setup
        bootstrap.start
        bootstrap.resource_manager.stub(:remaining_memory).and_return(100)
        bootstrap.resource_manager.stub(:memory_capacity).and_return(200)

        req = discover_message("droplet" => 0)
        nats_mock.request("dea.discover", req) do |msg|
          hello = Yajl::Parser.parse(msg)
          done
        end
      end

      actual_delay = Time.now - start
      expected_delay = (0.5 * Dea::Bootstrap::DISCOVER_DELAY_MS_MEM) / 1000

      verify_hello_message(bootstrap, hello)
      actual_delay.should be_within(0.05).of(expected_delay)
    end

    it "should cap its delay at a maximum" do
      hello = nil
      start = Time.now

      em(:timeout => 1) do
        bootstrap.setup
        bootstrap.start

        ninstances_needed =
          Dea::Bootstrap::DISCOVER_DELAY_MS_MAX / Dea::Bootstrap::DISCOVER_DELAY_MS_PER_INSTANCE

        instances = (0..(ninstances_needed + 1)).to_a
        bootstrap.instance_registry                \
                 .stub(:instances_for_application) \
                 .and_return(instances)

        req = discover_message("droplet" => 0)
        nats_mock.request("dea.discover", req) do |msg|
          hello = Yajl::Parser.parse(msg)
          done
        end
      end

      actual_delay = Time.now - start
      expected_delay = (Dea::Bootstrap::DISCOVER_DELAY_MS_MAX.to_f / 1000)

      verify_hello_message(bootstrap, hello)
      actual_delay.should be_within(0.1).of(expected_delay)
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
