require 'spec_helper'
require 'dea/utils/platform_compat'

describe FileUtils do
  platform_specific(:platform)

  describe "#cp_a" do
    context "on Linux" do
      let(:platform) { :Linux }
      it "Copies files using system command" do
        # recursively (-r) while not following symlinks (-P) and preserving dir structure (-p)
        # this is why we use system copy not FileUtil
        FileUtils.should_receive(:system).with("cp -a fakesrcdir fakedestdir/app")
        FileUtils.cp_a "fakesrcdir", "fakedestdir/app"
      end
    end

    context "on Windows" do
      let(:platform) { :Windows }
      it "Copies files using FileUtils" do
        FileUtils.should_receive(:cp_r).with("fakesrcdir", "fakedestdir/app", { :preserve => true })
        FileUtils.cp_a "fakesrcdir", "fakedestdir/app"
      end
    end
  end
end

describe PlatformCompat do
  platform_specific(:platform)
  describe "#signal_supported?" do
    context "on Linux" do
      let(:platform) { :Linux }
      it "supports SIGUSR1" do
        PlatformCompat.signal_supported?("SIGUSR1").should be_true
      end
    end

    context "on Windows" do
      let(:platform) { :Windows }
      it "supports SIGTERM" do
        PlatformCompat.signal_supported?("SIGTERM").should be_true
      end
    end
  end

  describe "#to_env" do
    context "on Linux" do
      let(:platform) { :Linux }
      it "uses export command" do
        expect(PlatformCompat.to_env({"foo" => "bar"})).to eq %Q{export foo="bar";\n}
      end
      it "encodes double quotes" do
        expect(PlatformCompat.to_env({"foo" => %Q{bar"foo"}})).to eq "export foo=\"bar\\\"foo\\\"\";\n"
      end
    end

    context "on Windows" do
      let(:platform) { :Windows }
      it "uses PowerShell env: namespace" do
        expect(PlatformCompat.to_env({"foo" => "bar"})).to eq %Q{$env:foo='bar'\n}
      end
    end
  end
end