require 'spec_helper'

describe VCAP::Dea::Server do
  include_context :nats

  let(:dea) do
    handler = VCAP::Dea::Handler.new(nil)
    VCAP::Dea::Server.new(@nats_config[:uri], handler)
  end

  it "should respond to messages published on 'dea.status'" do
    reply = nil

    nats do
      Fiber.new do
        f_wait_for_dea
        reply = f_nats_request('dea.status')
        NATS.stop
        EM.stop
      end.resume
      dea.start
    end

    reply.should_not be_nil
    reply['uuid'].should == dea.handler.uuid
    reply['version'].should == VCAP::Dea::VERSION
  end
end
