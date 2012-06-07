$:.unshift(File.dirname(__FILE__))
require 'spec_helper'
require 'fiber_aware_helpers'
require 'tempfile'
require 'eventmachine'

describe VCAP::Dea::FiberAwareHelpers do
  let(:helpers_klass) { Class.new { include VCAP::Dea::FiberAwareHelpers } }
  let(:helpers) { helpers_klass.new }

  describe '#defer' do
    it 'should return the result of the supplied block' do
      tmpfile = Tempfile.open('test') do |f|
        f.write('TESTING123')
        f
      end

      expected_sha1 = Digest::SHA1.file(tmpfile.path).hexdigest
      computed_sha1 = nil

      em do
        Fiber.new do
          computed_sha1 = helpers.defer do
            Digest::SHA1.file(tmpfile.path).hexdigest
          end
          EM.stop
        end.resume
      end

      computed_sha1.should == expected_sha1
    end

    it 'should propagate exceptions that are thrown in the deferred block' do
      expect do
        em do
          Fiber.new do
            helpers.defer { raise StandardError.new("testing123") }
          end.resume
        end
      end.to raise_error(/testing123/)
    end
  end

  describe '#sh' do
    it 'should return the status, stdout, and standard error of commands' do
      em do
        Fiber.new do
          status, stdout, stderr = helpers.sh("echo -n HELLO")
          EM.stop
          status.exitstatus.should == 0
          stdout.should == "HELLO"
          stderr.should == ""
        end.resume
      end
    end
  end
end
