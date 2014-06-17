require 'spec_helper'
require "dea/utils/non_blocking_unzipper"

describe NonBlockingUnzipper do
  describe "#unzip_to_folder" do
    let(:zip) {"file.zip"}
    let(:dest) { Dir.mktmpdir }
    let(:status) {double(exitstatus: 0)}

    subject { NonBlockingUnzipper.new.unzip_to_folder(zip, dest) {} }

    after(:each) {
      FileUtils.rm_rf(dest)
    }

    it "invokes unzip" do
      allow(EM).to receive(:system).with(/unzip -q #{zip} -d/)

      subject
    end

    it "the destintation is available on success" do
      allow(EM).to receive(:system).with(/unzip/).and_return('', status)

      subject
      expect(File.exists?(dest)).to be_true
    end

    it "has the correct file mode on the destination directory" do
      allow(EM).to receive(:system).with(/unzip/).and_return('', status)

      subject
      expect(File.stat(dest).mode) == 0755
    end


    context "when unzip fails" do
      let(:status) {double(exitstatus: 1)}
      let(:tmpdir) {double(:file)}

      it "removes the temporary directory on failure" do
        allow(Dir).to receive(:mktmpdir).and_return(tmpdir)
        allow(File).to receive(:chmod).with(0755, tmpdir)
        allow(EM).to receive(:system).with(/unzip/).and_return('', status)
        allow(tmpdir).to receive(:unlink)

        subject
      end
    end

    it "passes the status code to the provided block" do
      allow(EM).to receive(:system).with(/unzip/).and_return('', status)

      subject do |status|
        expect(status).to_be eq(0)
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
