$:.unshift(File.dirname(__FILE__))
require 'spec_helper'
require 'tempfile'
require 'fileutils'
require 'warden_env'

describe VCAP::Dea::WardenEnv, :needs_warden => true do
  it "test file copy in and out" do
    em_fiber_wrap {
      test_file = 'test'
      out_file_path = '/tmp/outfile'
      f = Tempfile.new('test')
      begin
        warden_env = VCAP::Dea::WardenEnv.new
        test_file_path = f.path
        warden_env.copy_in(test_file_path, test_file)
        warden_env.file_exists?(test_file).should == true
        warden_env.copy_out(test_file, out_file_path)
        File.exists?(out_file_path).should == true
      ensure
        f.unlink
        FileUtils.rm_f out_file_path if File.exists?(out_file_path)
      end
    }
  end

  it "run a command" do
    em_fiber_wrap {
      warden_env = VCAP::Dea::WardenEnv.new
      status, out, err = warden_env.run("echo foo")
      out.chop.should == 'foo'
      warden_env.destroy!
    }
  end

end

