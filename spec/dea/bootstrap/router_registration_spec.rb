# coding: UTF-8

require "spec_helper"
require "dea/bootstrap"

describe Dea do
  include_context "bootstrap_setup"

  before do
    bootstrap.unstub(:setup_router_client)
    bootstrap.unstub(:setup_directory_server_v2)
    bootstrap.unstub(:directory_server_v2)
    bootstrap.unstub(:register_directory_server_v2)
  end

  it "should publish two messages on 'router.register' upon receipt of a message on 'router.start'" do
    instances = []
    responses = []

    nats_mock.subscribe("router.register") do |msg, _|
      responses << Yajl::Parser.parse(msg)
      done
    end

    em(:timeout => 1) do
      bootstrap.setup
      bootstrap.start

      states = [Dea::Instance::State::RUNNING,
                Dea::Instance::State::STOPPED,
                Dea::Instance::State::RUNNING]
      all_uris = [["foo"], ["bar"], []]

      states.zip(all_uris).each_with_index do |(state, uris), ii|
        instance = create_and_register_instance(bootstrap,
                                                "application_id"   => ii.to_s,
                                                "application_uris" => uris)
        instance.state = state
        instances << instance
      end

      nats_mock.publish("router.start")
    end

    expected_0 = {
      "dea"  => bootstrap.uuid,
      "app"  => instances[0].application_id,
      "uris" => instances[0].application_uris,
      "host" => bootstrap.local_ip,
      "port" => instances[0].instance_host_port,
      "tags" => {
        "framework" => instances[0].framework_name,
        "runtime"   => instances[0].runtime_name,
      },
      "private_instance_id" => instances[0].private_instance_id,
    }

    expected_1 = {
      "host" => bootstrap.local_ip,
      "port" => bootstrap.config["directory_server"]["v2_port"],
      "uris" => ["#{bootstrap.directory_server_v2.uuid}.#{bootstrap.config["domain"]}"],
      "tags" => {},
    }

    # The directory server is registered at startup, thus we expect two
    # registrations to arrive
    responses.should =~ [expected_0, expected_1, expected_1]
  end

  describe "upon receipt of a message on 'dea.update'" do
    it "should register new uris" do
      uris = []
      new_uris = []

      reqs = {}
      nats_mock.subscribe("router.register") do |msg, _|
        req = Yajl::Parser.parse(msg)
        reqs[req["app"]] = req
        done if reqs.size == 2
      end

      em(:timeout => 1) do
        bootstrap.setup
        bootstrap.start

        uris = 2.times.map do |ii|
          uri = "http://www.foo.com/#{ii}"
          create_and_register_instance(bootstrap,
                                       "application_id"   => ii.to_s,
                                       "application_uris" => [uri])
          uri
        end

        new_uris = 2.times.map do |ii|
          ["http://www.foo.com/#{ii + 2}"]
        end

        new_uris.each_with_index do |uri, ii|
          nats_mock.publish("dea.update",
                            { "droplet" => ii,
                              "uris"    => [uris[ii], new_uris[ii]].flatten })
        end
      end

      2.times do |ii|
        reqs[ii.to_s].should_not be_nil
        reqs[ii.to_s]["uris"].should == new_uris[ii]
      end
    end

    it "should unregister stale uris" do
      old_uris = {}
      new_uris = {}

      reqs = {}
      nats_mock.subscribe("router.unregister") do |msg, _|
        req = Yajl::Parser.parse(msg)
        reqs[req["app"]] = req
        done if reqs.size == 2
      end

      em(:timeout => 1) do
        bootstrap.setup
        bootstrap.start

        2.times do |ii|
          uris = 2.times.map { |jj| "http://www.foo.com/#{ii + jj}" }
          create_and_register_instance(bootstrap,
                                       "application_id"   => ii.to_s,
                                       "application_uris" => uris)
        end

        bootstrap.instance_registry.each do |instance|
          app_id = instance.application_id
          old_uris[app_id.to_s] = instance.application_uris
          new_uris[app_id.to_s] = instance.application_uris.slice(1, 1)
          nats_mock.publish("dea.update",
                            { "droplet" => app_id,
                              "uris"    => new_uris[app_id]})
        end
      end

      bootstrap.instance_registry.each do |instance|
        app_id = instance.application_id
        reqs[app_id.to_s].should_not be_nil
        reqs[app_id.to_s]["uris"].should == (old_uris[app_id] - new_uris[app_id])
      end
    end

    it "should update the instance's uris" do
      instance = nil
      uris = []

      em(:timeout => 1) do
        bootstrap.setup
        bootstrap.start

        instance = create_and_register_instance(bootstrap,
                                                "application_id"   => 0.to_s,
                                                "application_uris" => [])

        uris = 2.times.map { |ii| "http://www.foo.com/#{ii}" }
        nats_mock.publish("dea.update",
                          { "droplet" => instance.application_id,
                            "uris"    => uris})

        EM.next_tick { done }
      end

      instance.application_uris.should == uris
    end
  end
end
