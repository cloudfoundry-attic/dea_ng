# coding: UTF-8

require 'spec_helper'
require 'dea/pid_file'

describe '.process_running' do
end

describe Dea::PidFile do
  before :all do
    @pid_file = "/tmp/pidfile_test_%d_%d_%d" % [Process.pid(), Time.now().to_i(), rand(1000)]
  end

  after :each do
    FileUtils.rm_f(@pid_file)
  end

  it "should create a pidfile if one doesn't exist" do
    Dea::PidFile.new(@pid_file)
    expect(File.exists?(@pid_file)).to be true
  end


  it "should overwrite pid file if pid file exists and contained pid isn't running" do
    fork { Dea::PidFile.new(@pid_file) }

    Process.wait()
    Dea::PidFile.new(@pid_file)
    pid = File.open(@pid_file) {|f| pid = f.read().strip().to_i()}
    expect(pid).to eq Process.pid()
  end

  it "should throw exception if pid file exists and contained pid has running process" do
    child_pid = fork {
      Dea::PidFile.new(@pid_file)
      Signal.trap('HUP') { exit }
      while true; end
    }
    sleep(1)
    thrown = false
    begin
      Dea::PidFile.new(@pid_file)
    rescue Dea::PidFile::ProcessRunningError => e
      thrown = true
    end
    Process.kill('HUP', child_pid)
    Process.wait()
    expect(thrown).to be true
  end

  it "shouldn't throw an exception if current process's pid is in pid file" do
    expect{Dea::PidFile.new(@pid_file)}.to_not raise_error
    expect{Dea::PidFile.new(@pid_file)}.to_not raise_error
  end
  
  describe '#unlink' do
    it "should remove pidfile correctly" do
      pf = Dea::PidFile.new(@pid_file)
      pf.unlink()
      expect(File.exists?(@pid_file)).to be false
    end
  end

  describe '#unlink_at_exit' do
    it "should remove pidfile upon exit", unix_only: true do
      child_pid = fork {
        pf = Dea::PidFile.new(@pid_file)
        pf.unlink_at_exit()
        Signal.trap('HUP') { exit }
        while true; end
      }
      sleep 1
      Process.kill('HUP', child_pid)
      Process.wait()
      expect(File.exists?(@pid_file)).to be false
    end
  end
end

