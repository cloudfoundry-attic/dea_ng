require 'spec_helper'
require 'webmock/rspec'

class TestMessage
  attr_reader :reply_value, :details

  def initialize(details={})
    @reply_value = nil
    @details     = details
  end

  def reply(val)
    @reply_value = val
  end
end

describe VCAP::Dea::Handler do
  include_context :warden

  let(:runtimes) { {'test_runtime' => '/does/not/exist'} }

  let(:default_limits) { {'mem' => 128, 'disk' => 256} }

  let(:uri) { 'http://www.foobar/com/baz' }

  describe '#get_status' do
    it 'should respond with a status reply' do
      handler = VCAP::Dea::Handler.new(nil, runtimes)
      msg = TestMessage.new
      handler.get_status(msg)
      msg.reply_value.should_not be_nil
      msg.reply_value.keys.should == [:uuid, :version]
    end
  end

  describe '#start_instance' do
    it 'should raise an error on unsupported runtimes' do
      handler = VCAP::Dea::Handler.new(nil, runtimes)
      msg = TestMessage.new('runtime' => 'unsupported')
      expect_handler_error(/runtime unsupported/i) do
        handler.start_instance(msg)
      end
    end

    it 'should raise an error if desired resources cannot be allocated' do
      handler = VCAP::Dea::Handler.new(nil, runtimes,
                                       :resource_capacities => {:memory_mb => 10})
      msg = TestMessage.new('runtime' => 'test_runtime',
                            'limits'  => {'mem' => 100})
      expect_handler_error(/insufficient resources/i) do
        handler.start_instance(msg)
      end
    end

    it 'should raise an error if downloading the droplet fails' do
      handler = VCAP::Dea::Handler.new(nil, runtimes)
      msg = TestMessage.new('runtime'       => 'test_runtime',
                            'executableUri' => uri,
                            'limits'        => default_limits)
      stub_request(:get, uri).to_return(:status => 500)
      expect_handler_error(/failed downloading droplet/i) do
        handler.start_instance(msg)
      end
    end

    it 'should raise an error on sha1 mismatch for the downloaded droplet' do
      handler = VCAP::Dea::Handler.new(nil, runtimes)
      msg = TestMessage.new('runtime'       => 'test_runtime',
                            'executableUri' => uri,
                            'sha1'          => 'invalid',
                            'limits'        => default_limits)
      stub_request(:get, uri).to_return(:status => 200, :body => 'testing123')
      expect_handler_error(/sha1 mismatch/i) do
        handler.start_instance(msg)
      end
    end

    it 'should raise an error if droplet extraction fails' do
      handler = VCAP::Dea::Handler.new(nil, runtimes)
      body = 'not a tgz'
      sha1 = Digest::SHA1.hexdigest(body)
      msg = TestMessage.new('runtime'       => 'test_runtime',
                            'executableUri' => uri,
                            'sha1'          => sha1,
                            'limits'        => default_limits)
      stub_request(:get, uri).to_return(:status => 200, :body => body)
      expect_handler_error(/droplet extraction failed/i) do
        handler.start_instance(msg)
      end
    end

    it 'should start the application instance', :needs_warden => true do
      tmpdir = Dir.mktmpdir
      test_droplet_path = File.join(tmpdir, 'droplet.tgz')
      create_test_droplet(test_droplet_path)
      body = File.read(test_droplet_path)
      sha1 = Digest::SHA1.hexdigest(body)
      msg = TestMessage.new('runtime'       => 'test_runtime',
                            'executableUri' => uri,
                            'sha1'          => sha1,
                            'limits'        => default_limits)
      stub_request(:get, uri).to_return(:status => 200, :body => body)
      handler = VCAP::Dea::Handler.new(warden_socket_path, runtimes)
      handler_invocation(:timeout => 5) do
        handler.start_instance(msg)
      end
    end
  end

  def handler_invocation(em_run_opts={}, &blk)
    em(em_run_opts) do
      Fiber.new do
        result = blk.call
        EM.stop
        result
      end.resume
    end
  end

  def expect_handler_error(error_regex, &blk)
    expect do
      handler_invocation(&blk)
    end.to raise_error(error_regex)
  end
end
