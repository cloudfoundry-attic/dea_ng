require "spec_helper"
require "dea/starting/instance_uri_updater"
require "dea/starting/instance"

describe Dea::InstanceUriUpdater do
  let(:app_uris) { ["app.cfapps.io", "app.run.pivotal.io"] }
  let(:instance) { instance_double("Dea::Instance") }
  let(:router_client) { instance_double("Dea::RouterClient") }

  before do
    allow(instance).to receive(:application_uris).and_return(app_uris)
    allow(instance).to receive(:application_uris=).and_return(app_uris)
  end

  it "adds new uris" do
    new_uris = ["app.cfapps.io", "app.run.pivotal.io", "new.cfapps.io"]
    updater = Dea::InstanceUriUpdater.new(instance, new_uris)
    expect(router_client).to receive(:register_instance).with(instance, uris: ["new.cfapps.io"])
    expect(updater.update(router_client)).to be true
  end

  it "removes obsolete uris" do
    new_uris = ["app.cfapps.io"]
    updater = Dea::InstanceUriUpdater.new(instance, new_uris)
    expect(router_client).to receive(:unregister_instance).with(instance, uris: ["app.run.pivotal.io"])
    expect(updater.update(router_client)).to be true
  end

  it "updates the app instance with the current uris" do
    new_uris = ["app.cfapps.io", "app.example.com"]
    updater = Dea::InstanceUriUpdater.new(instance, new_uris)

    expect(router_client).to receive(:unregister_instance).with(instance, uris: ["app.run.pivotal.io"])
    expect(router_client).to receive(:register_instance).with(instance, uris: ["app.example.com"])
    expect(instance).to receive(:application_uris=).with(new_uris)
    updater.update(router_client)
  end

  it "does nothing if the uris have not changed" do
    updater = Dea::InstanceUriUpdater.new(instance, app_uris)
    expect(updater.update(router_client)).to be false
  end
end
