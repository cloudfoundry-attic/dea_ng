# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  before do
    allow(bootstrap).to receive(:setup_directory_server).and_call_original
    allow(bootstrap).to receive(:setup_directory_server_v2).and_call_original
    allow(bootstrap).to receive(:directory_server_v2).and_call_original
  end

  describe "responses to messages received on 'dea.find.droplet'" do
    def run
      with_event_machine(:timeout => 1) do
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
      first_instance = nil

      run do
        first_instance = @instances[0]
        responses = find_droplet(:count => 1) do
          {
            "droplet" => first_instance.application_id,
          }
        end
      end

      expected = {
        "dea"      => bootstrap.uuid,
        "droplet"  => first_instance.application_id,
        "version"  => first_instance.application_version,
        "instance" => first_instance.instance_id,
        "index"    => first_instance.instance_index,
        "state"    => first_instance.state,
        "state_timestamp" => first_instance.state_timestamp,
      }

      expect(responses.size).to eq(1)
      expect(responses[0]).to include(expected)
    end

    it "should include a v2 url if the path key is present" do
      responses = []

      run do
        first_instance = @instances[0]
        responses = find_droplet(:count => 1) do
          { "droplet" => first_instance.application_id,
            "path"    => "/foo/bar",
          }
        end
      end

      expect(responses.size).to eq(1)
      expect(responses[0]["file_uri_v2"]).to_not be_nil
    end

    it "should include 'stats' if requested" do
      responses = []

      expected = nil
      run do
        first_instance = @instances[0]

        # Stub time for uptime and usage calculations
        frozen_time = Time.now
        allow(Time).to receive(:now).and_return(frozen_time)

        expected = {
          "name"       => first_instance.application_name,
          "uris"       => first_instance.application_uris,
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
        allow(first_instance).to receive(:instance_host_port).and_return(expected["port"])

        # Limits
        allow(first_instance).to receive(:memory_limit_in_bytes).and_return(expected["mem_quota"])
        allow(first_instance).to receive(:disk_limit_in_bytes).and_return(expected["disk_quota"])
        allow(first_instance).to receive(:file_descriptor_limit).and_return(expected["fds_quota"])

        # Uptime
        allow(first_instance).to receive(:state_starting_timestamp).and_return(frozen_time - 1)

        responses = find_droplet(:count => 1) do
          {
            "droplet" => first_instance.application_id,
            "include_stats" => true,
          }
        end
      end

      expect(responses.size).to eq(1)
      expect(responses[0]["stats"]).to_not be_nil
      expect(responses[0]["stats"]).to eq(expected)
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

      expect(responses.size).to eq(1)
      expect(responses[0]["instance"]).to eq(@instances[1].instance_id)
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

      expect(responses.size).to eq(1)
      expect(responses[0]["instance"]).to eq(@instances[2].instance_id)
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

      expect(responses.size).to eq(1)
      expect(responses[0]["instance"]).to eq(@instances[2].instance_id)
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

          expect(responses.size).to eq(2)
          ids = responses.map { |r| r["instance"] }
          expect(ids.include?(@instances[1].instance_id)).to be true
          expect(ids.include?(@instances[2].instance_id)).to be true
        end
      end
    end
  end
end
