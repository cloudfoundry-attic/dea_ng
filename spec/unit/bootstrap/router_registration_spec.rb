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

  it "registers the directory server and instances on a time interval" do
    instances = []
    responses = []

    nats_mock.subscribe("router.register") do |msg, _|
      responses << Yajl::Parser.parse(msg)
      done
    end

    with_event_machine do
      allow(EM).to receive(:add_periodic_timer)
      bootstrap.setup

      states = [Dea::Instance::State::RUNNING,
                Dea::Instance::State::STOPPED,
                Dea::Instance::State::RUNNING]
      all_uris = [["foo"], ["bar"], []]

      states.zip(all_uris).each_with_index do |(state, uris), app_id|
        instance = create_and_register_instance(bootstrap,
                                                "application_id"   => app_id.to_s,
                                                "application_uris" => uris)
        instance.state = state
        instances << instance
      end

      bootstrap.start
      expect(EM).to have_received(:add_periodic_timer).with(20)

      done
    end

    expected_0 = {
      "dea"  => bootstrap.uuid,
      "app"  => instances[0].application_id,
      "uris" => instances[0].application_uris,
      "host" => bootstrap.local_ip,
      "port" => instances[0].instance_host_port,
      "tags" => { "component" => "dea-#{bootstrap.uuid}" },
      "private_instance_id" => instances[0].private_instance_id,
    }

    expected_1 = {
      "host" => bootstrap.local_ip,
      "port" => bootstrap.config["directory_server"]["v2_port"],
      "uris" => ["#{bootstrap.directory_server_v2.uuid}.#{bootstrap.config["domain"]}"],
      "tags" => { "component" => "directory-server-#{bootstrap.uuid}" },
    }

    # The directory server is registered at startup, thus we expect two
    # registrations to arrive
    expect(responses).to match_array([expected_0, expected_1])
  end

  describe "router.register message" do
    # The collector looks for dea- prefixed component tags
    it "includes a 'component' tag that starts with 'dea-' and ends with its index" do
      bs = double
      nats = double
      instance = double

      bs.stub(:nats).and_return(nats)
      bs.stub(:uuid).and_return("1-deadbeef")
      bs.stub(:config).and_return({ "index" => 1 })

      instance.stub(:application_id)
      instance.stub(:application_uris)
      bs.stub(:local_ip)
      instance.stub(:instance_host_port)
      instance.stub(:private_instance_id)

      nats.should_receive(:publish).with(anything, hash_including("tags" => hash_including("component" => "dea-1")))
      client = Dea::RouterClient.new(bs)
      client.register_instance(instance)
    end
  end

  describe "handle_router_start" do
    it "registers its routes" do
      bootstrap.setup

      instance = create_and_register_instance(bootstrap,
        "application_id" => "app_id",
        "application_uris" => ["iamaroute"])
      instance.state = Dea::Instance::State::RUNNING

      allow(bootstrap.router_client).to receive(:register_instance)
      allow(bootstrap.router_client).to receive(:register_directory_server)

      bootstrap.handle_router_start

      expect(bootstrap.router_client).to have_received(:register_instance).with(instance)

      domain = "#{bootstrap.directory_server_v2.uuid}.#{bootstrap.config["domain"]}"
      port = bootstrap.config["directory_server"]["v2_port"]
      expect(bootstrap.router_client).to have_received(:register_directory_server).with(port, domain)
    end
  end

  describe "upon receipt of a message on 'dea.update'" do
    context "when updating running instances" do
      it "should register new uris" do
        uris = []
        new_uris = []

        reqs = {}
        nats_mock.subscribe("router.register") do |msg, _|
          req = Yajl::Parser.parse(msg)
          reqs[req["app"]] = req
          done if reqs.size == 2
        end

        with_event_machine(:timeout => 1) do
          bootstrap.setup
          bootstrap.start

          uris = 2.times.map do |ii|
            uri = "http://www.foo.com/#{ii}"
            instance = create_and_register_instance(bootstrap,
                                                    "application_id"   => ii.to_s,
                                                    "application_uris" => [uri])
            instance.state = Dea::Instance::State::RUNNING
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

        with_event_machine(:timeout => 1) do
          bootstrap.setup
          bootstrap.start

          2.times do |ii|
            uris = 2.times.map { |jj| "http://www.foo.com/#{ii + jj}" }
            instance = create_and_register_instance(bootstrap,
                                                    "application_id"   => ii.to_s,
                                                    "application_uris" => uris)
            instance.state = Dea::Instance::State::RUNNING
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

      describe "updating the instance registry" do
        let(:instance) do
          instance = create_and_register_instance(bootstrap,
                                                  "application_id"   => 0.to_s,
                                                  "application_uris" => ["old-uri"],
                                                  "application_version" => "old-version")
          instance.state = Dea::Instance::State::RUNNING
          instance
        end

        before do
          bootstrap.setup
        end

        context "when both the uris and app version are specified" do
          it "updates the instance's uris and app version" do
            expect {
              with_event_machine do
                bootstrap.start

                nats_mock.publish("dea.update",
                                  { "droplet" => instance.application_id,
                                    "uris"    => ["new-uri"],
                                    "version" => "new-version"
                                  })

                EM.next_tick { done }
              end
            }.to change {
              [instance.application_uris, instance.application_version]
            }.from([["old-uri"], "old-version"]).to([["new-uri"], "new-version"])
          end

          it "changes the instance's id" do
            bootstrap.instance_registry.lookup_instance(instance.instance_id).should == instance

            expect {
              with_event_machine do
                bootstrap.start

                nats_mock.publish("dea.update",
                                  { "droplet" => instance.application_id,
                                    "uris"    => ["new-uri"],
                                    "version" => "new-version"
                                  })

                EM.next_tick { done }
              end
            }.to change { instance.instance_id }

            bootstrap.instance_registry.lookup_instance(instance.instance_id).should == instance
          end
        end
      end
    end

    context "when updating an instance that is not running" do
      let(:instance) do
        instance = create_and_register_instance(bootstrap,
                                                "application_id"   => 0.to_s,
                                                "application_uris" => ["old-uri"],
                                                "application_version" => "old-version")
        instance.state = Dea::Instance::State::STARTING
        instance
      end

      before do
        bootstrap.setup
      end

      it "should not change uri registration or version" do
        expect {
          with_event_machine do
            bootstrap.start

            nats_mock.publish("dea.update",
                              { "droplet" => instance.application_id,
                                "uris"    => ["new-uri"],
                                "version" => "new-version"
                              })

            EM.next_tick { done }
          end
        }.to_not change {
          [instance.application_uris, instance.application_version]
        }
      end

      it "should not change the instance's id" do
        bootstrap.instance_registry.lookup_instance(instance.instance_id).should == instance

        expect {
          with_event_machine do
            bootstrap.start

            nats_mock.publish("dea.update",
                              { "droplet" => instance.application_id,
                                "uris"    => ["new-uri"],
                                "version" => "new-version"
                              })

            EM.next_tick { done }
          end
        }.to_not change {
          instance.instance_id
        }

        bootstrap.instance_registry.lookup_instance(instance.instance_id).should == instance
      end
    end
  end
end
