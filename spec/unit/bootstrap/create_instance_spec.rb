require "spec_helper"
require "dea/bootstrap"

describe "Dea::Bootstrap#create_instance" do
  include_context "bootstrap_setup"

  let(:router_client) do
    client = mock('router_client')
    client.stub(:register_instance)
    client.stub(:unregister_instance)
    client
  end

  let(:resource_manager) do
    manager = double(:resource_manager)
    manager.stub(:could_reserve?).and_return(true)
    manager
  end

  before do
    bootstrap.unstub(:setup_router_client)
    bootstrap.stub(:router_client).and_return(router_client)
    bootstrap.stub(:nats).and_return(nats_mock)
    bootstrap.stub(:resource_manager).and_return(resource_manager)
    bootstrap.setup

    Dea::Instance.any_instance.stub(:setup_link)
    bootstrap.stub(:instances_filtered_by_message).and_yield(instance)

    instance.stub(:promise_stop).and_return(delivering_promise)
    instance.stub(:promise_copy_out).and_return(delivering_promise)
    instance.stub(:promise_destroy).and_return(delivering_promise)
    instance.stub(:close_warden_connections)
    instance.stub(:destroy)
  end

  subject(:instance) do
    instance = bootstrap.create_instance(valid_instance_attributes.merge('warden_handle' => 'handle'))
    instance.state = Dea::Instance::State::RUNNING

    instance
  end

  describe "publishes droplet.exited during state transitions" do
    context "when the app crashes" do
      it "calls the crash handler" do
        instance.should_receive(:crash_handler)
        instance.state = Dea::Instance::State::CRASHED
      end

      it "publishes to droplet.exited" do
        bootstrap.nats.should_receive(:publish) do |subject, data|
          expect(subject).to eq("droplet.exited")
          expect(data).to eq Dea::Protocol::V1::ExitMessage.generate(instance, Dea::Bootstrap::EXIT_REASON_CRASHED)
        end

        instance.stub(:exit_status).and_return(128)
        instance.stub(:exit_description).and_return("The instance crashed!")
        instance.state = Dea::Instance::State::CRASHED
      end
    end

    context "when the app is stopping" do
      it "doesn't call the crash handler" do
        instance.should_not_receive(:crash_handler)
        instance.state = Dea::Instance::State::STOPPING
      end

      it "publishes to droplet.exited" do
        bootstrap.nats.should_receive(:publish) do |subject, data|
          expect(subject).to eq("droplet.exited")
          expect(data).to eq Dea::Protocol::V1::ExitMessage.generate(instance, Dea::Bootstrap::EXIT_REASON_STOPPED)
        end

        instance.stub(:exit_status).and_return(0)
        instance.stub(:exit_description).and_return("The instance is stopping!")
        instance.state = Dea::Instance::State::STOPPING
      end
    end
  end
end
