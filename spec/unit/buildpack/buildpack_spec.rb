require "spec_helper"

describe Buildpacks::Buildpack, type: :buildpack do
  let(:fake_buildpacks_dir) { fixture("fake_buildpacks") }
  let(:buildpack_dirs) { Pathname(fake_buildpacks_dir).children.map(&:to_s) }
  let(:dest_dir) { "fakedestdir" }
  let(:config) do
    {
      "environment" => {"services" => []},
      "source_dir" => "fakesrcdir",
      "dest_dir" => dest_dir,
      "staging_info_path" => File.join(dest_dir, "fake_staging_info.yml"),
      "buildpack_dirs" => buildpack_dirs
    }
  end

  let(:build_pack) { Buildpacks::Buildpack.new(config) }

  describe "#stage_application" do
    let(:buildpack_name) { "Not Rubby" }

    before { allow(build_pack).to receive(:build_pack) { double(:build_pack, name: buildpack_name) } }

    it "runs from the correct folder" do
      allow(Dir).to receive(:chdir).with(File.expand_path "fakedestdir").and_yield
      allow(build_pack).to receive(:create_app_directories).ordered
      allow(build_pack).to receive(:copy_source_files).ordered
      allow(build_pack).to receive(:compile_with_timeout).ordered
      allow(build_pack).to receive(:save_buildpack_info).ordered
      expect(build_pack).to_not receive(:save_error_info)
      build_pack.stage_application
    end

    context "when a staging error is raised" do
      let(:staging_error) { Buildpacks::NoAppDetectedError.new("no buildpacks") }

      it "saves the error information and exits with failure" do
        allow(Dir).to receive(:chdir).with(File.expand_path "fakedestdir").and_yield
        allow(build_pack).to receive(:create_app_directories).ordered
        allow(build_pack).to receive(:copy_source_files).ordered
        allow(build_pack).to receive(:compile_with_timeout).ordered.and_raise(staging_error)
        expect(build_pack).to_not receive(:save_buildpack_info)

        allow(build_pack).to receive(:save_error_info).ordered.with(staging_error)
        allow($stdout).to receive(:puts).with("Staging failed: #{staging_error.message}")
        expect {
          build_pack.stage_application
        }.to raise_exception(SystemExit)
      end
    end
  end

  describe "#create_app_directories" do
    it "should make the correct directories" do
      allow(FileUtils).to receive(:mkdir_p).with(File.expand_path "fakedestdir/app")
      allow(FileUtils).to receive(:mkdir_p).with(File.expand_path "fakedestdir/logs")
      allow(FileUtils).to receive(:mkdir_p).with(File.expand_path "fakedestdir/tmp")

      build_pack.create_app_directories
    end
  end

  describe "#copy_source_files" do
    it "Copy all the files from the source dir into the dest dir" do
      # recursively (-r) while not following symlinks (-P) and preserving dir structure (-p)
      # this is why we use system copy not FileUtil
      allow(build_pack).to receive(:system).with("cp -a #{File.expand_path "fakesrcdir"}/. #{File.expand_path "fakedestdir/app"}")
      allow(FileUtils).to receive(:chmod_R).with(0744, File.expand_path("fakedestdir/app"))
      build_pack.copy_source_files
    end
  end

  describe "#compile_with_timeout" do
    before { allow(build_pack).to receive_message_chain(:build_pack, :compile) { sleep duration } }

    context "when the staging takes too long" do
      let(:duration) { 1 }

      it "kills the process group for the compilation task" do
        expect(Process).to receive(:kill).with(15, -Process.getpgid(Process.pid))

        build_pack.compile_with_timeout(0.01)
      end
    end

    context "when the staging completes within the timeout" do
      let(:duration) { 0 }

      it "does not kill the process group" do
        allow(Process).to receive(:kill)

        build_pack.compile_with_timeout(0.1)

        expect(Process).not_to have_received(:kill)
      end
    end
  end

  describe "#save_buildpack_info" do
    let(:dest_dir) { @destination_dir }
    let(:buildpack) { Buildpacks::Buildpack.new(config) }

    def buildpack_info
      @buildpack_info ||= begin
        Dir.mktmpdir do |tmp|
          @destination_dir = tmp

          FileUtils.cp_r(app_source, File.join(tmp, "app"))

          buildpack.save_buildpack_info
          YAML.load_file(File.join(tmp, "fake_staging_info.yml"))
        end
      end
    end

    context "when passing in multiple buildpacks" do
      before { app_fixture :node_with_procfile }

      let(:buildpack_dirs) do
        [
          "#{fake_buildpacks_dir}/fail_to_detect",
          "#{fake_buildpacks_dir}/start_command",
          "#{fake_buildpacks_dir}/ruby",
        ]
      end

      it "tries next buildpack in a set if first fails to detect" do
        expect(buildpack_info["detected_buildpack"]).to eq("Node.js")
      end

      context "when multiple buildpacks match" do
        let(:buildpack_dirs) do
          [
            "#{fake_buildpacks_dir}/fail_to_detect",
            "#{fake_buildpacks_dir}/ruby",
            "#{fake_buildpacks_dir}/start_command",
          ]
        end

        it "searches the buildpacks in order" do
         expect(buildpack_info["detected_buildpack"]).to eq("Ruby/Rails")
        end
      end
    end

    context "when the buildpack is detected" do
      before { app_fixture :node_with_procfile }

      let(:buildpack_dirs) { ["#{fake_buildpacks_dir}/no_start_command"] }

      it "has the detected buildpack" do
        expect(buildpack_info["detected_buildpack"]).to eq("Node.js")
      end

      it "has the buildpack path" do
        expect(buildpack_info["buildpack_path"]).to eq("#{fake_buildpacks_dir}/no_start_command")
      end

      it "has a nil specified_buildpack_key" do
        expect(buildpack_info["specified_buildpack_key"]).to be_nil
      end

      it "has a nil custom buildpack url" do
        expect(buildpack_info["custom_buildpack_url"]).to be_nil
      end

      context "when the application has a procfile" do
        let(:buildpack_dirs) { ["#{fake_buildpacks_dir}/admin_buildpack"] }

        it "uses the start command specified by the 'web' key in the procfile" do
          expect(buildpack_info["start_command"]).to eq("node app.js --from-procfile=true")
        end

        it 'returns saves the procfile into the staging info' do
          expected_procfile = {
            "web" => "node app.js --from-procfile=true"
          }
          expect(buildpack_info['effective_procfile']).to eq(expected_procfile)
        end
      end

      context 'when the application does not have a procfile' do
        let(:buildpack_dirs) { ["#{fake_buildpacks_dir}/admin_buildpack"] }

        before { app_fixture :node_without_procfile }

        it 'returns the default procfile from the buildpack release metadata' do
          expected_procfile = {
            "web" => 'while true; do (echo "hi from admin buildpack" | nc -l $PORT); done'
          }
          expect(buildpack_info['effective_procfile']).to eq(expected_procfile)
        end

        context 'and it tries to install the buildpack' do
          let(:buildpacksInstaller) { double(Buildpacks::Installer, path: nil, name: nil, release_info: {}) }
          before do
            allow_any_instance_of(Buildpacks::Buildpack).to receive(:build_pack).and_return(buildpacksInstaller)
          end

          it 'calls the buildpack release method only once' do
            expect(buildpacksInstaller).to receive(:release_info).once
            expect{ buildpack_info }.to_not raise_error
          end
        end
      end
    end

    context "when no start command is passed and the application does not have a procfile" do
      before { app_fixture :node_without_procfile }

      context "when the buildpack provides a default start command" do
        let(:buildpack_dirs) { ["#{fake_buildpacks_dir}/start_command"] }

        it "uses the default start command" do
          expect(buildpack_info["start_command"]).to eq("while true; do (echo $(env) | nc -l $PORT); done")
        end
      end

      context "when the buildpack does not provide a default start command" do
        let(:buildpack_dirs) { ["#{fake_buildpacks_dir}/no_start_command"] }

        it "sets the start command to an empty string" do
          expect(buildpack_info["start_command"]).to be_nil
        end
      end

      context "when staging an app which does not match any build packs" do
        let(:buildpack_dirs) { ["#{fake_buildpacks_dir}/fail_to_detect"] }

        it "raises an error" do
          expect {
            buildpack_info
          }.to raise_error(Buildpacks::NoAppDetectedError, "An application could not be detected by any available buildpack")
        end
      end
    end
  end

  describe "#save_error_info" do
    let(:dest_dir) { @destination_dir }
    let(:buildpack) { Buildpacks::Buildpack.new(config) }
    let(:staging_info_file) { config["staging_info_path"] }

    before { @destination_dir = Dir.mktmpdir }
    after { FileUtils.rm_rf @destination_dir }

    it "saves the error information in the approprate directory" do
      expect(File.exists?(staging_info_file)).to be false
      buildpack.save_error_info(StandardError.new("my error"))
      expect(File.exists?(staging_info_file)).to be true
    end

    it "saves the base class name without module or namesapce" do
      buildpack.save_error_info(::Buildpacks::StagingError.new("staging error"))
      expect(YAML.load_file(staging_info_file)["staging_error"]["type"]).to eq("StagingError")
    end

    it "saves the message from the original exception" do
      buildpack.save_error_info(StandardError.new("original exception message"))
      expect(YAML.load_file(staging_info_file)["staging_error"]["message"]).to eq("original exception message")
    end
  end

  describe "buildpack_key" do
    let(:buildpack_dirs) { Pathname(fake_buildpacks_dir).children.map(&:to_s) }

    before do
      config["environment"]["buildpack_key"] = "fail_to_detect"
    end

    subject { build_pack.build_pack }

    it "returns the buildpack with the right key from the buildpack cache" do
      allow(Buildpacks::Installer).to receive(:new)
        .with("#{fake_buildpacks_dir}/fail_to_detect", anything, anything)
        .and_return("the right buildpack")

      expect(subject).to eq("the right buildpack")
    end

    it "does not try to detect the buildpack" do
      allow(build_pack).to receive(:system).with(anything) { true }

      build_pack.send(:installers).each do |i|
        expect(i).to_not receive(:detect)
      end

      subject
    end
  end

  describe "buildpack_git_url" do
    let(:buildpack_dirs) { ["#{fake_buildpacks_dir}/start_command"] }

    shared_examples "when a buildpack URL is passed" do |buildpack_url_config_key|
      let(:buildpack_url) { "git://github.com/heroku/heroku-buildpack-java.git" }
      let(:destination) { '/tmp/buildpacks' }
      let(:buildpack_dir) { "#{destination}/heroku-buildpack-java"}

      before { config["environment"][buildpack_url_config_key] = buildpack_url }

      subject { build_pack.build_pack }

      it "clones the buildpack URL" do
        allow(Buildpacks::Git).to receive(:clone).with(buildpack_url, destination).and_return(buildpack_dir)

        subject
      end

      context "with a branch" do
        let(:buildpack_url) { "git://github.com/heroku/heroku-buildpack-java.git#branch" }

        it "clones the buildpack" do
          allow(Buildpacks::Git).to receive(:clone).with(buildpack_url, destination).and_return(buildpack_dir)

          subject
        end
      end

      it "does not try to detect the buildpack" do
        allow(Buildpacks::Git).to receive(:clone) { buildpack_dir }

        build_pack.send(:installers).each do |i|
          expect(i).to_not receive(:detect)
        end

        subject
      end

      context "when an invalid uri is provided" do
        let(:buildpack_url) { "http://user:passw#ord@github.com/heroku/heroku-buildpack-java.git#branch" }

        it "raises an error" do
          expect { subject }.to raise_error(URI::InvalidURIError)
        end
      end
    end

    context "the old buildpack url key" do
      # soon to be deprecated.  Needs to stay around through one deploy so that things
      # don't break during the deploy
      include_examples "when a buildpack URL is passed", "buildpack"
    end

    context "the new, more clear, buildpack_git_url key" do
      include_examples "when a buildpack URL is passed", "buildpack_git_url"
    end
  end
end
