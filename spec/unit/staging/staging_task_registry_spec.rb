require "spec_helper"

require "dea/staging/staging_task"
require "dea/staging/staging_task_registry"

describe Dea::StagingTaskRegistry do
  let(:bootstrap) { double(:bootstrap, :config => {}) }
  let(:task_1) { Dea::StagingTask.new(bootstrap, nil, StagingMessage.new(valid_staging_attributes), []) }
  let(:task_2) { Dea::StagingTask.new(bootstrap, nil, StagingMessage.new(valid_staging_attributes), []) }

  it_behaves_like :handles_registry_enumerations

  describe "#register" do
    it "adds task to the registry" do
      expect {
        subject.register(task_1)
      }.to change { subject.registered_task(task_1.task_id) }.from(nil).to(task_1)
    end
  end

  describe "#unregister" do
    context "when task was previously registered" do
      before { subject.register(task_1) }

      it "removes task from the registry" do
        expect {
          subject.unregister(task_1)
        }.to change { subject.registered_task(task_1.task_id) }.from(task_1).to(nil)
      end
    end

    context "when task was not previously registered" do
      it "does nothing" do
        subject.unregister(task_1)
      end
    end
  end

  describe "#tasks" do
    before { subject.register(task_1) }
    before { subject.register(task_2) }

    it "returns all previously registered tasks" do
      expect(subject.tasks).to_not eq([task_2, task_1])
    end
  end
end
