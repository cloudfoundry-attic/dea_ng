require "spec_helper"

describe Buildpacks::Buildpack, :type => :buildpack do
  let(:fake_buildpacks_dir) { fixture("fake_buildpacks") }
  let(:buildpack_dirs) { Pathname(fake_buildpacks_dir).children.map(&:to_s) }
  let(:config) do
    {
      "environment" => {"services" => []},
      "source_dir" => "fakesrcdir",
      "dest_dir" => "fakedestdir",
      "staging_info_name" => "fake_staging_info.yml",
      "buildpack_dirs" => buildpack_dirs
    }
  end

  let(:build_pack) { Buildpacks::Buildpack.new(config) }

  describe "#stage_application" do
    let(:buildpack_name) { "Not Rubby" }

    before { build_pack.stub(:build_pack) { double(:build_pack, name: buildpack_name) } }

    it "runs from the correct folder" do
      Dir.should_receive(:chdir).with(File.expand_path "fakedestdir").and_yield
      build_pack.should_receive(:create_app_directories).ordered
      build_pack.should_receive(:copy_source_files).ordered
      build_pack.should_receive(:compile_with_timeout).ordered
      build_pack.should_receive(:save_buildpack_info).ordered
      build_pack.stage_application
    end
  end

  describe "#create_app_directories" do
    it "should make the correct directories" do
      FileUtils.should_receive(:mkdir_p).with(File.expand_path "fakedestdir/app")
      FileUtils.should_receive(:mkdir_p).with(File.expand_path "fakedestdir/logs")
      FileUtils.should_receive(:mkdir_p).with(File.expand_path "fakedestdir/tmp")

      build_pack.create_app_directories
    end
  end

  describe "#copy_source_files", unix_only:true do
    it "Copy all the files from the source dir into the dest dir" do
      # recursively (-r) while not following symlinks (-P) and preserving dir structure (-p)
      # this is why we use system copy not FileUtil
      build_pack.should_receive(:system).with("cp -a #{File.expand_path "fakesrcdir"}/. #{File.expand_path "fakedestdir/app"}")
      FileUtils.should_receive(:chmod_R).with(0744, File.expand_path("fakedestdir/app"))
      build_pack.copy_source_files
    end
  end

  describe "#copy_source_files on windows", windows_only:true do
    it "Copy all the files from the source dir into the dest dir" do
      stub_const('VCAP::WINDOWS', true)
      FileUtils.should_receive(:cp_r).with(File.expand_path("fakesrcdir") + "/.", File.expand_path("fakedestdir/app"))
      FileUtils.should_receive(:chmod_R).with(0744, File.expand_path("fakedestdir/app"))
      build_pack.copy_source_files
    end
  end

  describe "#compile_with_timeout" do
    before { build_pack.stub_chain(:build_pack, :compile) { sleep duration } }

    context "when the staging takes too long" do
      let(:duration) { 1 }

      it "times out" do
        expect {
          build_pack.compile_with_timeout(0.01)
        }.to raise_error(Timeout::Error)
      end
    end

    context "when the staging completes within the timeout" do
      let(:duration) { 0 }

      it "does not time out" do
        expect {
          build_pack.compile_with_timeout(0.1)
        }.to_not raise_error
      end
    end
  end

  describe "#save_buildpack_info" do
    let(:config) do
      {
        "environment" => {
          "services" => []
        },
        "source_dir" => "",
        "dest_dir" => @destination_dir,
        "staging_info_name" => "fake_staging_info.yml",
        "buildpack_dirs" => buildpack_dirs
      }
    end

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

    context "when passing in multiple buildpacks", unix_only:true do
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

    context "when the buildpack is detected", unix_only:true do
      before { app_fixture :node_with_procfile }

      let(:buildpack_dirs) { ["#{fake_buildpacks_dir}/no_start_command"] }

      it "has the detected buildpack" do
        expect(buildpack_info["detected_buildpack"]).to eq("Node.js")
      end

      context "when the application has a procfile" do
        it "uses the start command specified by the 'web' key in the procfile" do
          expect(buildpack_info["start_command"]).to eq("node app.js --from-procfile=true")
        end
      end
    end

    context "when no start command is passed and the application does not have a procfile" do
      before { app_fixture :node_without_procfile }

      context "when the buildpack provides a default start command", unix_only:true do
        let(:buildpack_dirs) { ["#{fake_buildpacks_dir}/start_command"] }

        it "uses the default start command" do
          expect(buildpack_info["start_command"]).to eq("while true; do (echo hi | nc -l $PORT); done")
        end
      end

      context "when the buildpack does not provide a default start command", unix_only:true  do
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
          }.to raise_error("Unable to detect a supported application type")
        end
      end
    end
  end

  describe "buildpack_key" do
    let(:buildpack_dirs) { Pathname(fake_buildpacks_dir).children.map(&:to_s) }

    before do
      config["environment"]["buildpack_key"] = "fail_to_detect"
    end

    subject { build_pack.build_pack }

    it "returns the buildpack with the right key from the buildpack cache" do
      Buildpacks::Installer.stub(:new)
        .with("#{fake_buildpacks_dir}/fail_to_detect", anything, anything)
        .and_return("the right buildpack")

      expect(subject).to eq("the right buildpack")
    end

    it "does not try to detect the buildpack" do
      build_pack.stub(:system).with(anything) { true }

      build_pack.send(:installers).each do |i|
        i.should_not_receive(:detect)
      end

      subject
    end
  end

  describe "buildpack_git_url" do
    let(:buildpack_dirs) { ["#{fake_buildpacks_dir}/start_command"] }

    shared_examples "when a buildpack URL is passed" do |buildpack_url_config_key|
      let(:buildpack_url) { "git://github.com/heroku/heroku-buildpack-java.git" }
      before { config["environment"][buildpack_url_config_key] = buildpack_url }

      subject { build_pack.build_pack }

      it "clones the buildpack URL" do
        build_pack.should_receive(:system).with(anything) do |cmd|
          expect(cmd).to match /git clone --recursive #{buildpack_url} \/tmp\/buildpacks/
          true
        end

        subject
      end

      it "does not try to detect the buildpack" do
        build_pack.stub(:system).with(anything) { true }

        build_pack.send(:installers).each do |i|
          i.should_not_receive(:detect)
        end

        subject
      end

      context "when the cloning fails" do
        it "gives up and raises an error" do
          build_pack.stub(:system).with(anything) { false }
          expect { subject }.to raise_error("Failed to git clone buildpack")
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

