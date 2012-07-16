$:.unshift(File.dirname(__FILE__))
require 'spec_helper'
require 'webmock/rspec'
require 'tempfile'
require 'http_util'

describe VCAP::Dea::HttpUtil do
  describe '#download' do
    describe 'on success' do
      it 'it should return the path to a file containing the uris contents' do
        uri = 'http://www.foobar.com/baz'
        body = 'TESTING123'
        body_path = nil
        stub_request(:get, uri).to_return(:body => body, :status => 200)

        em do
          Fiber.new do
            body_path = VCAP::Dea::HttpUtil.download(uri)
            EM.stop
          end.resume
        end

        body_path.should_not be_nil
        File.read(body_path).should == body
      end
    end

    describe 'on failure' do
      it 'should return nil' do
        uri = 'http://www.foobar.com/baz'
        body = 'TESTING123'
        body_path = nil
        stub_request(:get, uri).to_return(:body => body, :status => 500)

        em do
          Fiber.new do
            body_path = VCAP::Dea::HttpUtil.download(uri)
            EM.stop
          end.resume
        end

        body_path.should be_nil
      end
    end
  end
end
