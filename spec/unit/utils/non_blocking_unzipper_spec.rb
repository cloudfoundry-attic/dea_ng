require 'spec_helper'
require 'posix/spawn'
require "dea/utils/non_blocking_unzipper"

class FakeEM
  class Status < Struct.new(:exitstatus)
  end
  def initialize(return_status)
    @fixed_return_status = Status.new(return_status)
  end

  def system(cmd, &blk)
    Kernel.system(cmd) if @fixed_return_status.exitstatus == 0
    blk.call("out", @fixed_return_status, &Proc.new{})
  end
end

module TestZip
  def self.create(zip_name, file_count, file_size=1024)
    files = []
    file_count.times do |i|
      tf = Tempfile.new("ziptest_#{i}")
      files << tf
      tf.write("A" * file_size)
      tf.close
    end

    child = POSIX::Spawn::Child.new("zip", zip_name, *files.map(&:path))
    child.status.exitstatus == 0 or raise "Failed zipping:\n#{child.err}\n#{child.out}"
  end
end

describe NonBlockingUnzipper do
  describe "#unzip_to_folder" do
    def mktmpzipfile
      path = File.join(Dir.mktmpdir, "what.zip")
      TestZip.create(path, 1, 1024)
      path
    end

    let(:zip) {"file.zip"}
    let(:dest) { Dir.mktmpdir }
    let(:status) {double(exitstatus: 0)}

    subject { NonBlockingUnzipper.new.unzip_to_folder(zip, dest) {} }

    after(:each) {
      FileUtils.rm_rf(dest)
    }

    it "invokes unzip into the destination directory" do
        stub_const("EM", FakeEM.new(0))

        tmpdir = Dir.mktmpdir
        dest_dir = Dir.mktmpdir
        zip = mktmpzipfile
        allow(Dir).to receive(:mktmpdir).and_return(tmpdir)

        NonBlockingUnzipper.new.unzip_to_folder(zip, dest_dir) do |output, exitcode|
          expect(exitcode).to eq(0)
        end

        expect(Dir.exist?(tmpdir)).to eq(false)
        expect(Dir.entries(dest_dir).size).to eq(3)
        expect(File.stat(dest_dir).mode) == 0755
    end

    context "when unzip fails" do
      it "doesn't raise if unzip fails and removes intermediate temp directory" do
        stub_const("EM", FakeEM.new(1))

        tmpdir = Dir.mktmpdir
        dest_dir = Dir.mktmpdir
        zip = mktmpzipfile
        allow(Dir).to receive(:mktmpdir).and_return(tmpdir)

        NonBlockingUnzipper.new.unzip_to_folder(zip, dest_dir) do |output, exitcode|
          expect(exitcode).to eq(1)
        end

        expect(Dir.exist?(tmpdir)).to eq(false)
      end
    end

    context "when move fails halfway (moves aren't atomic between /tmp and ephemeral filesystem)" do
      let(:status) {double(exitstatus: 0)}

      before do
        allow(EM).to receive(:system).with(/unzip/) do |&block|
          block.call("", status)
        end

        expect(FileUtils).to receive(:mv) do |from, to|
          Dir.mkdir(to)
          File.open(File.join(to, "foo.txt"), 'w') do |file|
            file.write("something something")
          end

          raise "the move fails half-way"
        end
      end

      it "completely succeeds, or no files are copied" do
        subject
        expect(Pathname.new(dest).children).to be_empty
      end
    end
  end
end
