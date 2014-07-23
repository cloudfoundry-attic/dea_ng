require "spec_helper"
require "dea/bootstrap"

describe Dea::InstanceManager do
  describe "#create_instance" do
    let(:state) { Dea::Instance::State::BORN }
    let(:attributes) { valid_instance_attributes.merge("state" => state) }
    let(:instance) { Dea::Instance.new(bootstrap, attributes) }
    before do
      Dea::Instance.stub(:new => instance)
      instance.stub(:setup => nil)
    end

    let(:could_reserve) { true }
    let(:constrained_resource) { nil }
    let(:resource_manager) do
      double(:resource_manager, :could_reserve? => could_reserve, :get_constrained_resource => constrained_resource)
    end

    let(:instance_registry) do
      double(:instance_registry, :register => nil, :unregister => nil)
    end

    let(:snapshot) { double(:snapshot, :save => nil) }

    let(:router_client) { double(:router_client, :register_instance => nil, :unregister_instance => nil) }

    let(:bootstrap) do
      double(:bootstrap,
             :config => {},
             :resource_manager => resource_manager,
             :send_exited_message => nil,
             :send_heartbeat => nil,
             :send_instance_stop_message => nil,
             :instance_registry => instance_registry,
             :snapshot => snapshot,
             :router_client => router_client,
      )
    end

    let(:message_bus) do
      bus = double(:message_bus)
      @published_messages = {}
      allow(bus).to receive(:publish) do |subject, message|
        @published_messages[subject] ||= []
        @published_messages[subject] << message
      end
      bus
    end

    subject(:instance_manager) { Dea::InstanceManager.new(bootstrap, message_bus) }

    context "when it successfully validates" do
      context "when there are not enough resources available" do
        let(:could_reserve) { false }

        let(:constrained_resource) { "memory" }

        it "logs error indicating not enough resource available" do
          instance_manager.logger.should_receive(:error).with(
            "instance.start.insufficient-resource",
            hash_including(:app => "37", :instance => 42, :constrained_resource => "memory"))
          instance_manager.create_instance(attributes)
        end

        it "marks app as crashed" do
          instance_manager.create_instance(attributes)
          expect(instance.exit_description).to match(/memory/)
          expect(instance.state).to eq Dea::Instance::State::CRASHED
        end

        it "sends exited message" do
          instance_manager.create_instance(attributes)
          expect(@published_messages["droplet.exited"]).to have(1).item
          expect(@published_messages["droplet.exited"].first["reason"]).to eq "CRASHED"
          expect(@published_messages["droplet.exited"].first["instance"]).to eq instance.instance_id
        end

        it "returns nil" do
          expect(instance_manager.create_instance(attributes)).to be_nil
        end
      end

      context "when there is enough resources available" do
        it "sets up an instance" do
          instance.should_receive(:setup)
          instance_manager.create_instance(attributes)
        end

        it "registers instance in instance registry" do
          instance_registry.should_receive(:register).with(instance)
          instance_manager.create_instance(attributes)
        end

        it "returns the new instance" do
          expect(instance_manager.create_instance(attributes)).to eq(instance)
        end

        describe "state transitions" do
          before do
            instance_manager.create_instance(attributes)
          end

          context "when the app is born" do
            context "and it transitions to crashed" do
              subject { instance.state = Dea::Instance::State::CRASHED }

              it "sends exited message with reason: crashed" do
                subject
                expect(@published_messages["droplet.exited"]).to have(1).item
                expect(@published_messages["droplet.exited"].first["reason"]).to eq "CRASHED"
                expect(@published_messages["droplet.exited"].first["instance"]).to eq instance.instance_id
              end
            end
          end

          context "when the app is starting" do
            before do
              instance.state = Dea::Instance::State::STARTING
            end

            context "and it transitions to running" do
              subject { instance.state = Dea::Instance::State::RUNNING }

              it "sends heartbeat" do
                bootstrap.should_receive(:send_heartbeat)
                subject
              end

              it "registers with the router" do
                bootstrap.router_client.should_receive(:register_instance).with(instance)
                subject
              end

              it "saves the snapshot" do
                bootstrap.snapshot.should_receive(:save)
                subject
              end
            end

            context "and it transitions to crashed" do
              subject { instance.state = Dea::Instance::State::CRASHED }

              it "sends exited message with reason: crashed" do
                subject
                expect(@published_messages["droplet.exited"]).to have(1).item
                expect(@published_messages["droplet.exited"].first["reason"]).to eq "CRASHED"
                expect(@published_messages["droplet.exited"].first["instance"]).to eq instance.instance_id
              end
            end
          end

          context "when the app is running" do
            before do
              instance.state = Dea::Instance::State::RUNNING
            end

            context "and it transitions to crashed" do
              subject { instance.state = Dea::Instance::State::CRASHED }

              it "unregisters with the router" do
                bootstrap.router_client.should_receive(:unregister_instance).with(instance)
                subject
              end

              it "sends exited message with reason: crashed" do
                subject
                expect(@published_messages["droplet.exited"]).to have(1).item
                expect(@published_messages["droplet.exited"].first["reason"]).to eq "CRASHED"
                expect(@published_messages["droplet.exited"].first["instance"]).to eq instance.instance_id
              end

              it "saves the snapshot" do
                bootstrap.snapshot.should_receive(:save)
                subject
              end
            end

            context "and it transitions to stopping" do
              subject { instance.state = Dea::Instance::State::STOPPING }

              it "unregisters with the router" do
                bootstrap.router_client.should_receive(:unregister_instance).with(instance)
                subject
              end

              it "saves the snapshot" do
                bootstrap.snapshot.should_receive(:save)
                subject
              end
            end
          end

          context "when the app is stopping" do
            before do
              ::EM.stub(:next_tick).and_yield
              instance.state = Dea::Instance::State::STOPPING
            end

            context "and it transitions to stopped" do
              subject { instance.state = Dea::Instance::State::STOPPED }

              it "unregisters from the instance registry" do
                instance_registry.should_receive(:unregister).with(instance)
                subject
              end

              it "saves the snapshot" do
                bootstrap.snapshot.should_receive(:save)
                subject
              end

              it "destroys the instance" do
                instance.should_receive(:destroy)
                subject
              end
            end
          end

          context "when the app is evacuating" do
            before do
              instance.state = Dea::Instance::State::EVACUATING
            end

            context "and it transitions to stopping" do
              subject { instance.state = Dea::Instance::State::STOPPING }

              it "unregisters with the router" do
                bootstrap.router_client.should_receive(:unregister_instance).with(instance)
                subject
              end

              it "saves the snapshot" do
                bootstrap.snapshot.should_receive(:save)
                subject
              end
            end
          end
        end
      end
    end

    context "when validation fails" do
      let(:attributes) { {} }

      it "does not start the instance" do
        instance.should_not_receive(:start)
        instance_manager.create_instance(attributes)
      end

      it "returns nil" do
        expect(instance_manager.create_instance(attributes)).to be_nil
      end
    end
  end
end
