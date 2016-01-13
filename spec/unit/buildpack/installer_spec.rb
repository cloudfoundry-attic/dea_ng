require "spec_helper"

describe Buildpacks::Installer, :type => :buildpack do
  subject { described_class.new(tmp_dir, "app_dir", "cache_dir") }
  let(:tmp_dir) { Dir.mktmpdir }

  let(:detect_path) { File.join(tmp_dir, "bin", "detect") }
  let(:detect_script) do
<<-HEREDOC
  exit 0
HEREDOC
  end

  let(:fake_stdout) { StringIO.new }

  def prepare_script(path, script)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "w") { |f| f.write(script) }
    FileUtils.chmod 0555, path
  end

  before do
    @original_stdout = $stdout
    $stdout = fake_stdout

    prepare_script(detect_path, detect_script)
  end

  after do
    FileUtils.rm_rf(tmp_dir)
    $stdout = @original_stdout
  end

  describe "detect" do
    it "returns true if detect script exits with 0" do
      expect(subject.detect).to be true
    end

    context "when detect script exits with non 0" do
      let(:detect_script) do
<<-HEREDOC
  exit 1
HEREDOC
      end

      it "returns false" do
        allow(Open3).to receive(:capture2).and_return(["", 1])
        expect(subject.detect).to be false
      end
    end

    context "when running detect script raises an error" do
      before do
        FileUtils.chmod 0400, detect_path
      end

      it "returns false if detect script raises any error" do
        expect(subject.detect).to be false
      end

      it "writes an error message to $stdout" do
        expect($stdout).to receive(:puts).with(/Failed to run buildpack detection script with error/)
        expect(subject.detect).to be false
      end
    end
  end

  describe "name" do
    context "when detect script returns an output" do
      let(:detect_script) do
<<-HEREDOC
  echo "Some Buildpack"
  exit 0
HEREDOC
      end

      it "should be used as a buildpack name" do
        subject.detect
        expect(subject.name).to eq("Some Buildpack")
      end
    end
  end

  describe "compile" do
    let(:compile_path) { File.join(tmp_dir, "bin", "compile") }
    let(:compile_script) do
<<-HEREDOC
  if [ "$1" != "app_dir" ]; then
    exit 1
  fi

  if [ "$2" != "cache_dir" ]; then
    exit 1
  fi

  exit 0
HEREDOC
    end

    before { prepare_script(compile_path, compile_script) }

    it "runs a compile script with a cache directory" do
      expect { subject.compile }.to_not raise_error
    end

    context "when script fails" do
      let(:compile_script) do
<<-HEREDOC
  exit 1
HEREDOC
      end

      it "raises a buildpack compile failed error if script fails" do
        expect {
          subject.compile
        }.to raise_error(Buildpacks::BuildpackCompileFailed, /Buildpack compilation step failed/)
      end
    end
  end

  describe "release_info" do
    let(:release_path) { File.join(tmp_dir, "bin", "release") }
    let(:release_script) do
<<-HEREDOC
cat <<YAML
---
key: value
YAML
HEREDOC
    end

    before { prepare_script(release_path, release_script) }
    it "loads release info yaml" do
      expect(subject.release_info).to eq("key" => "value")
    end

    context "when release fails" do
      it "raises a buildpack release failed error" do
        expect(Open3).to receive(:capture2).and_return(["Error", 1])
        expect {
          subject.release_info
        }.to raise_error(Buildpacks::BuildpackReleaseFailed, /Release info failed/)
      end
    end
  end
end
