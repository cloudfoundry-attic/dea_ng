require 'spec_helper'

describe Buildpacks::Buildpack, :type => :buildpack do
  let(:fake_buildpacks_dir) { File.expand_path("../../../fixtures/fake_buildpack_dirs", __FILE__) }
  let(:config) do
    {
      "environment" => {"services" => []},
      "source_dir" => "fakesrcdir",
      "dest_dir" => "fakedestdir",
      "staging_info_name" => "fake_staging_info.yml",
    }
  end
  let(:build_pack) { Buildpacks::Buildpack.new(config) }

  before do
    Buildpacks::Buildpack.any_instance.stub(:buildpacks_path) { Pathname.new(buildpacks_path) }
  end

  shared_examples_for "successful buildpack compilation" do
    it "copies the app directory to the correct destination" do
      stage :environment => staging_env do |staged_dir|
        File.should be_file("#{staged_dir}/app/app.js")
      end
    end

    it "puts the environment variables provided by 'release' into the startup script" do
      stage :environment => staging_env do |staged_dir|
        start_script = File.join(staged_dir, 'startup')
        script_body = File.read(start_script)
        script_body.should include('export FROM_BUILD_PACK="${FROM_BUILD_PACK:-yes}"')
      end
    end

    it "ensures all files have executable permissions" do
      stage :environment => staging_env do |staged_dir|
        Dir.glob("#{staged_dir}/app/*").each do |file|
          expect(File.stat(file).mode.to_s(8)[3..5]).to eq("744") unless File.directory? file
        end
        start_script = File.join(staged_dir, 'startup')
        script_body = File.read(start_script)
        expect(script_body).to include('export FROM_BUILD_PACK="${FROM_BUILD_PACK:-yes}"')
      end
    end

    it "stores everything in profile" do
      stage :environment => staging_env do |staged_dir|
        start_script = File.join(staged_dir, 'start_cmd')
        start_script.should be_executable_file
        script_body = File.read(start_script)
        script_body.should include(<<-EXPECTED)
if [ -d app/.profile.d ]; then
  for i in app/.profile.d/*.sh; do
    if [ -r $i ]; then
      . $i
    fi
  done
  unset i
fi
        EXPECTED
      end
    end
  end

  describe "#stage_application" do
    let(:buildpack_name) { "Not Rubby" }

    before { build_pack.stub(:build_pack) { mock(:build_pack, name: buildpack_name) } }

    it "runs from the correct folder" do
      Dir.should_receive(:chdir).with(File.expand_path "fakedestdir").and_yield
      build_pack.should_receive(:create_app_directories).ordered
      build_pack.should_receive(:copy_source_files).ordered
      build_pack.should_receive(:compile_with_timeout).ordered
      build_pack.should_not_receive(:stage_rails_console)
      build_pack.should_receive(:save_buildpack_info).ordered
      build_pack.stage_application
    end

    context "when rails buildpack" do
      let(:buildpack_name) { "Ruby/Rails" }
      it "stages the console" do
        Dir.should_receive(:chdir).with(File.expand_path "fakedestdir").and_yield
        build_pack.should_receive(:create_app_directories)
        build_pack.should_receive(:copy_source_files)
        build_pack.should_receive(:compile_with_timeout)
        build_pack.should_receive(:stage_rails_console)
        build_pack.should_receive(:save_buildpack_info)
        build_pack.stage_application
      end
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

  describe "#copy_source_files" do
    it "Copy all the files from the source dir into the dest dir" do
      # recursively (-r) while not following symlinks (-P) and preserving dir structure (-p)
      # this is why we use system copy not FileUtil
      build_pack.should_receive(:system).with("cp -a #{File.expand_path "fakesrcdir"}/. #{File.expand_path "fakedestdir/app"}")
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

  describe "#stage_rails_console" do
    before do
      FileUtils.stub(:mkdir_p)
      FileUtils.stub(:cp_r)
      File.stub(:open)
    end

    context "when a rails application is detected by the ruby buildpack" do
      let(:buildpacks_path) { buildpacks_path_with_rails }

      it "puts in the cf-rails-console app files" do
        FileUtils.should_receive(:mkdir_p).with(File.expand_path("fakedestdir/app/cf-rails-console"))
        FileUtils.should_receive(:cp_r).with(%r{.+buildpacks/lib/resources/cf-rails-console}, File.expand_path("fakedestdir/app"))

        build_pack.stage_rails_console
      end

      it "puts in the console access file" do
        fake_file = StringIO.new
        File.should_receive(:open).with(File.expand_path("fakedestdir/app/cf-rails-console/.consoleaccess"), "w").and_yield(fake_file)

        build_pack.stage_rails_console

        fake_file = fake_file.string
        expect(fake_file).to include("username: !binary ")
        expect(fake_file).to include("password: !binary ")
      end
    end
  end

  describe "#save_buildpack_info" do
    let(:config) do
      {
        "environment" => {
          "meta" => meta,
          "services" => []
        },
        "source_dir" => "",
        "dest_dir" => app_source,
        "staging_info_name" => "fake_staging_info.yml"
      }
    end
    let(:meta) { {} }
    let(:buildpack_name) { "fake ruby" }
    let(:buildpack) do
      build_pack = Buildpacks::Buildpack.new(config)
      build_pack.stub(:build_pack) do
        mock(:build_pack,
          name: buildpack_name,
          release_info: {"default_process_types" => {"web" => "fake start command from buildpack"}}
        )
      end
      build_pack
    end

    let(:buildpack_info_path) { File.join(buildpack.destination_directory, "fake_staging_info.yml") }
    let(:buildpack_info) do
      buildpack.save_buildpack_info
      YAML.load_file(buildpack_info_path)
    end

    before { app_fixture :node_without_procfile }

    after { FileUtils.rm(buildpack_info_path) if File.exists?(buildpack_info_path) }

    it "has the detected buildpack" do
      expect(buildpack_info["detected_buildpack"]).to eq("fake ruby")
    end

    context "when a start command is passed" do
      let(:meta) { {"command" => "fake user defined start command"} }

      it "has the start command" do
        expect(buildpack_info["start_command"]).to eq("fake user defined start command")
      end
    end

    context "when the application has a procfile" do
      before do
        Buildpacks::Procfile.stub(:new) { mock(:proc_file, web: "Mocked start command") }
      end

      it "uses the start command specified by the 'web' key in the procfile" do
        expect(buildpack_info["start_command"]).to eq("Mocked start command")
      end
    end

    context "when no start command is passed and the application does not have a procfile" do
      before { app_fixture :node_without_procfile }

      context "when the buildpack provides a default start command" do
        it "uses the default start command" do
          expect(buildpack_info["start_command"]).to eq("fake start command from buildpack")
        end
      end

      context "when the buildpack does not provide a default start command" do
        let(:buildpacks_path) { "#{fake_buildpacks_dir}/without_start_cmd" }

        it "raises an error " do
          expect {
            stage :environment => config["environment"]
          }.to raise_error("Please specify a web start command in your manifest.yml or Procfile")
        end
      end

      context "when staging an app which does not match any build packs" do
        let(:buildpacks_path) { "#{fake_buildpacks_dir}/with_no_match" }

        it "raises an error" do
          expect {
            stage :environment => config["environment"]
          }.to raise_error("Unable to detect a supported application type")
        end
      end
    end
  end

  describe "#build_pack" do
    let(:buildpacks_path) { "#{fake_buildpacks_dir}/with_start_cmd" }

    context "when a buildpack URL is passed" do
      let(:buildpack_url) { "git://github.com/heroku/heroku-buildpack-java.git" }
      before { config["environment"]["buildpack"] = buildpack_url }

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
  end
end

