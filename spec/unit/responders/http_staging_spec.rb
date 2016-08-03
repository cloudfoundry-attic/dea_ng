require 'spec_helper'

require 'dea/staging/staging_task_registry'

require 'dea/responders/http_staging'
require 'dea/responders/staging'

require 'dea/utils/cloud_controller_client'

describe Dea::Responders::HttpStaging do
  let(:cc_client) { double(Dea::CloudControllerClient) }
  let(:staging_message) { double(StagingMessage) }

  let(:request) { {'app_id' => 'app_id'} }
  let(:staging_task) do
    double(:staging_task,
      task_id: "task-id",
      streaming_log_url: "log url",
    )
  end

  let(:stager) { double(Dea::Responders::Staging, :create_task => staging_task) }

  subject { described_class.new(stager, cc_client) }

  describe '#handle' do
    let(:staging_message) { StagingMessage.new(nil) }

    before do
      allow(staging_message).to receive(:set_responder).and_call_original
      allow(StagingMessage).to receive(:new).with(request).and_return(staging_message)
    end

    it 'sets the responder to the cloud controller client' do
      allow(staging_task).to receive(:start) do
        staging_message.respond({}) do
          called = true
        end
      end

      expect(cc_client).to receive(:send_staging_response)

      subject.handle(request)
    end

    it 'starts the staging task' do
      allow(staging_message).to receive(:set_responder)
      expect(staging_task).to receive(:start)
      subject.handle(request)
    end

    context 'when creating a staging task fails' do
      before do
        allow(stager).to receive(:create_task).and_return(nil)
      end

      it 'does not start any staging task' do
        expect(staging_task).to_not receive(:start)
        subject.handle(request)
      end
    end
  end
end
