require "spec_helper"
require "dea/staging_task"
require "dea/staging_task_registry"

describe Dea::StagingTaskRegistry do
  let(:bootstrap) { mock(:bootstrap, :config => {}) }
  let(:task) { Dea::StagingTask.new(bootstrap, nil, {}) }

  describe "#register" do
    it "adds task to the registry" do
      expect {
        subject.register(task)
      }.to change { subject.registered_task(task.task_id) }.from(nil).to(task)
    end
  end

  describe "#unregister" do
    context "when task was previously registered" do
      before { subject.register(task) }

      it "removes task from the registry" do
        expect {
          subject.unregister(task)
        }.to change { subject.registered_task(task.task_id) }.from(task).to(nil)
      end
    end

    context "when task was not previously registered" do
      it "does nothing" do
        subject.unregister(task)
      end
    end
  end
end
