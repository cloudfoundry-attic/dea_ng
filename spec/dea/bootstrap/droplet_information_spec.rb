# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  before do
    bootstrap.unstub(:setup_directory_server)
    bootstrap.unstub(:setup_directory_server_v2)
    bootstrap.unstub(:directory_server_v2)
  end

  it "should reply to messages on 'droplet.status' with all live droplets" do
    responses = []
    instances = {}

    nats_mock.subscribe("result") do |msg, _|
      responses << Yajl::Parser.parse(msg)
      done if responses.size == 2
    end

    em(:timeout => 1) do
      bootstrap.setup
      bootstrap.start

      # Register one instance per state
      Dea::Instance::State.constants.each do |state|
        name = state.to_s
        instance = create_and_register_instance(bootstrap,
                                                "application_name" => name,
                                                "application_uris" => ["http://www.foo.bar/#{name}"])
        instance.state = Dea::Instance::State.const_get(state)
        instances[instance.application_name] = instance
      end

      nats_mock.publish("droplet.status", {}, "result")
    end

    responses.each do |r|
      ["RUNNING", "STARTING"].include?(r["name"]).should be_true
      r["uris"].should == instances[r["name"]].application_uris
    end
  end

  describe "responses to messages received on 'dea.find.droplet'" do
    def run
      em(:timeout => 1) do
        bootstrap.setup
        bootstrap.start

        @instances =
          [Dea::Instance::State::RUNNING,
           Dea::Instance::State::STOPPED,
           Dea::Instance::State::STARTING].each_with_index.map do |state, ii|
            instance = create_and_register_instance(bootstrap,
                                                    "application_id"      => ((ii == 0) ? 0 : 1).to_s,
                                                    "application_version" => ii,
                                                    "instance_index"      => ii,
                                                    "application_uris"    => ["foo", "bar"])
            instance.state = state
            instance
          end

        fiber = Fiber.new do
          yield
          done
        end

        fiber.resume
      end
    end

    def find_droplet(options)
      options[:count] ||= 1

      responses = []

      fiber = Fiber.current
      nats_mock.subscribe("result") do |msg|
        responses << Yajl::Parser.parse(msg)

        if responses.size == options[:count]
          EM.next_tick do
            fiber.resume(responses)
          end
        end
      end

      request = yield

      nats_mock.publish("dea.find.droplet", request, "result")

      Fiber.yield
    end

    it "should respond with a correctly formatted message" do
      responses = []

      run do
        responses = find_droplet(:count => 1) do
          {
            "droplet" => @instances[0].application_id,
          }
        end
      end

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

    it "should include a v2 url if the path key is present" do
      responses = []

      run do
        responses = find_droplet(:count => 1) do
          { "droplet" => @instances[0].application_id,
            "path"    => "/foo/bar",
          }
        end
      end

      responses.size.should == 1
      responses[0]["file_uri_v2"].should_not be_nil
    end

    it "should include 'stats' if requested" do
      responses = []

      expected = nil
      run do
        # Stub time for uptime and usage calculations
        frozen_time = Time.now
        Time.stub(:now).and_return(frozen_time)

        expected = {
          "name"       => @instances[0].application_name,
          "uris"       => @instances[0].application_uris,
          "host"       => bootstrap.local_ip,
          "port"       => 5,
          "uptime"     => 1,
          "mem_quota"  => 5,
          "disk_quota" => 10,
          "fds_quota"  => 15,
          "usage"      => {
            "cpu"  => 0,
            "mem"  => 0,
            "disk" => 0,
            "time" => frozen_time.to_s,
          }
        }

        # Port
        @instances[0].stub(:instance_host_port).and_return(expected["port"])

        # Limits
        getters = [:memory_limit_in_bytes, :disk_limit_in_bytes,
                   :file_descriptor_limit]
        keys = %W(mem disk fds)
        getters.zip(keys).each do |getter, key|
          @instances[0].stub(getter).and_return(expected["#{key}_quota"])
        end

        # Uptime
        @instances[0].stub(:state_starting_timestamp).and_return(frozen_time - 1)

        responses = find_droplet(:count => 1) do
          {
            "droplet" => @instances[0].application_id,
            "include_stats" => true,
          }
        end
      end

      responses.size.should == 1
      responses[0]["stats"].should_not be_nil
      responses[0]["stats"].should == expected
    end

    it "should support filtering by application version" do
      responses = []

      run do
        responses = find_droplet(:count => 1) do
          {
            "droplet" => @instances[1].application_id,
            "version" => @instances[1].application_version,
          }
        end
      end

      responses.size.should == 1
      responses[0]["instance"].should == @instances[1].instance_id
    end

    it "should support filtering by instance index" do
      responses = []

      run do
        responses = find_droplet(:count => 1) do
          {
            "droplet" => @instances[1].application_id,
            "indices" => [@instances[2].instance_index],
          }
        end
      end

      responses.size.should == 1
      responses[0]["instance"].should == @instances[2].instance_id
    end

    it "should support filtering by state" do
      responses = []

      run do
        responses = find_droplet(:count => 1) do
          {
            "droplet" => @instances[1].application_id,
            "states" => [@instances[2].state],
          }
        end
      end

      responses.size.should == 1
      responses[0]["instance"].should == @instances[2].instance_id
    end

    it "should support filtering with multiple values" do
      filters = %w[indices instances states]
      getters = %w[instance_index instance_id state].map(&:to_sym)

      run do
        filters.zip(getters).each do |filter, getter|
          responses = find_droplet(:count => 2) do
            {
              "droplet" => @instances[1].application_id,
              filter    => @instances.slice(1, 2).map(&getter),
            }
          end

          responses.size.should == 2
          ids = responses.map { |r| r["instance"] }
          ids.include?(@instances[1].instance_id).should be_true
          ids.include?(@instances[2].instance_id).should be_true
        end
      end
    end
  end
end
