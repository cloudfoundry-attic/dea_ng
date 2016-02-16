require "spec_helper"
require "dea/bootstrap"

describe Dea::InstanceManager do
  describe "#create_instance" do
    let(:state) { Dea::Instance::State::BORN }
    let(:requested_memory) { 512 }
    let(:memory_limit) { 512 }
    let(:resource_limits) do
      { "mem" => requested_memory, "disk" => 128, "fds" => 5000 }
    end
    let(:attributes) { valid_instance_attributes.merge("state" => state, "limits" => resource_limits) }
    let(:instance) { Dea::Instance.new(bootstrap, attributes) }
    before do
      allow(Dea::Instance).to receive(:new).and_return(instance)
      allow(instance).to receive(:setup).and_return(nil)
    end

    let(:staging_task_registry) { Dea::StagingTaskRegistry.new }
    let(:instance_registry) { Dea::InstanceRegistry.new }
    let(:resource_manager) { Dea::ResourceManager.new(instance_registry, staging_task_registry, {"memory_mb" => memory_limit}) }

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
        let(:requested_memory) { 1024 }

        it "logs error indicating not enough resource available" do
          allow(instance_manager.logger).to receive(:error).with(
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
          expect(@published_messages["droplet.exited"].size).to eq(1)
          expect(@published_messages["droplet.exited"].first["reason"]).to eq "CRASHED"
          expect(@published_messages["droplet.exited"].first["instance"]).to eq instance.instance_id
        end

        it "returns nil" do
          expect(instance_manager.create_instance(attributes)).to be_nil
        end
      end

      context "when there is enough resources available" do
        it "sets up an instance" do
          allow(instance).to receive(:setup)
          instance_manager.create_instance(attributes)
        end

        it "registers instance in instance registry" do
          allow(instance_registry).to receive(:register).with(instance)
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
                expect(@published_messages["droplet.exited"].size).to eq(1)
                expect(@published_messages["droplet.exited"].first["reason"]).to eq "CRASHED"
                expect(@published_messages["droplet.exited"].first["instance"]).to eq instance.instance_id
              end

              it "saves the snapshot" do
                expect(bootstrap.snapshot).to receive(:save)
                subject
              end
            end

            context "and it transitions to stopped" do
              subject { instance.state = Dea::Instance::State::STOPPED }

              before { allow(::EM).to receive(:next_tick).and_yield }

              it "unregisters from the instance registry" do
                allow(instance_registry).to receive(:unregister).with(instance)
                subject
              end

              it "saves the snapshot" do
                expect(bootstrap.snapshot).to receive(:save)
                subject
              end

              it "destroys the instance" do
                allow(instance).to receive(:destroy)
                subject
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
                allow(bootstrap).to receive(:send_heartbeat)
                subject
              end

              it "registers with the router" do
                allow(bootstrap.router_client).to receive(:register_instance).with(instance)
                subject
              end

              it "saves the snapshot" do
                expect(bootstrap.snapshot).to receive(:save)
                subject
              end
            end

            context "and it transitions to crashed" do
              subject { instance.state = Dea::Instance::State::CRASHED }

              it "sends exited message with reason: crashed" do
                subject
                expect(@published_messages["droplet.exited"].size).to eq(1)
                expect(@published_messages["droplet.exited"].first["reason"]).to eq "CRASHED"
                expect(@published_messages["droplet.exited"].first["instance"]).to eq instance.instance_id
              end

              it "saves the snapshot" do
                expect(bootstrap.snapshot).to receive(:save)
                subject
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
                expect(bootstrap.router_client).to receive(:unregister_instance).with(instance)
                subject
              end

              it "sends exited message with reason: crashed" do
                subject
                expect(@published_messages["droplet.exited"].size).to eq(1)
                expect(@published_messages["droplet.exited"].first["reason"]).to eq "CRASHED"
                expect(@published_messages["droplet.exited"].first["instance"]).to eq instance.instance_id
              end

              it "saves the snapshot" do
                expect(bootstrap.snapshot).to receive(:save)
                subject
              end
            end

            context "and it transitions to stopping" do
              subject { instance.state = Dea::Instance::State::STOPPING }

              it "unregisters with the router" do
                expect(bootstrap.router_client).to receive(:unregister_instance).with(instance)
                subject
              end

              it "saves the snapshot" do
                expect(bootstrap.snapshot).to receive(:save)
                subject
              end
            end
          end

          context "when the app is stopping" do
            before do
              allow(::EM).to receive(:next_tick).and_yield
              instance.state = Dea::Instance::State::STOPPING
            end

            context "and it transitions to stopped" do
              subject { instance.state = Dea::Instance::State::STOPPED }

              it "unregisters from the instance registry" do
                expect(instance_registry).to receive(:unregister).with(instance)
                subject
              end

              it "saves the snapshot" do
                expect(bootstrap.snapshot).to receive(:save)
                subject
              end

              it "destroys the instance" do
                allow(instance).to receive(:destroy)
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
                allow(bootstrap.router_client).to receive(:unregister_instance).with(instance)
                subject
              end

              it "saves the snapshot" do
                expect(bootstrap.snapshot).to receive(:save)
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
        expect(instance).to_not receive(:start)
        instance_manager.create_instance(attributes)
      end

      it "returns nil" do
        expect(instance_manager.create_instance(attributes)).to be_nil
      end
    end
  end
end
