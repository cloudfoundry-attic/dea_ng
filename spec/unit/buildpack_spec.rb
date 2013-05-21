require 'spec_helper'

describe Buildpacks::Buildpack, :type => :buildpack do
  let(:fake_buildpacks_dir) { File.expand_path("../../fixtures/fake_buildpack_dirs", __FILE__) }
  let(:buildpacks_path_with_start_cmd) { "#{fake_buildpacks_dir}/with_start_cmd" }
  let(:buildpacks_path_with_rails) { "#{fake_buildpacks_dir}/with_rails" }
  let(:buildpacks_path_without_start_cmd) { "#{fake_buildpacks_dir}/without_start_cmd" }
  let(:buildpacks_path_with_no_match) { "#{fake_buildpacks_dir}/with_no_match" }
  let(:buildpacks_path) { buildpacks_path_with_start_cmd }

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
        start_script = File.join(staged_dir, 'startup')
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

  let(:staging_env) { {} }

  context "when a buildpack URL is passed" do
    let(:buildpack_url) { "git://github.com/heroku/heroku-buildpack-java.git" }
    let(:staging_env) { { "buildpack" => buildpack_url } }
    let(:staging_config) {
      {
        "source_dir" => ".",
        "dest_dir" => ".",
        "environment" => staging_env
      }
    }
    let(:plugin) { Buildpacks::Buildpack.new(staging_config) }

    subject { plugin.build_pack }

    it "clones the buildpack URL" do
      plugin.should_receive(:system).with(/git clone/) do |cmd|
        expect(cmd).to match /git clone --depth 1 #{buildpack_url} \/tmp\/buildpacks/
        true
      end

      plugin.should_receive(:system).with(/git submodule/) do |cmd|
        expect(cmd).to match /cd \/tmp\/buildpacks\/heroku-buildpack-java.git && git submodule update --init --recursive/
        true
      end

      subject
    end

    it "does not try to detect the buildpack" do
      plugin.stub(:system).with(anything) { true }

      plugin.installers.each do |i|
        i.should_not_receive(:detect)
      end

      subject
    end

    context "when the cloning fails" do
      it "gives up and raises an error" do
        plugin.stub(:system).with(anything) { false }
        expect { subject }.to raise_error("Failed to git clone buildpack")
      end
    end
  end

  context "when a start command is passed" do
    let(:staging_env) { {"meta" => {"command" => "node app.js --from-manifest=true"}} }

    before { app_fixture :node_without_procfile }

    it_behaves_like "successful buildpack compilation"

    it "uses the passed start command" do
      stage :environment => staging_env do |staged_dir|
        packages_with_start_script(staged_dir, "node app.js --from-manifest=true")
      end
    end
  end

  context "when the application has a procfile" do
    before { app_fixture :node_with_procfile }

    it_behaves_like "successful buildpack compilation"

    it "uses the start command specified by the 'web' key in the procfile" do
      stage :environment => staging_env do |staged_dir|
        packages_with_start_script(staged_dir, "node app.js --from-procfile=true")
      end
    end

    it "raise a good error if the procfile is not a hash" do
      app_fixture :node_with_invalid_procfile
      expect {
        stage :environment => staging_env
      }.to raise_error("Invalid Procfile format.  Please ensure it is a valid YAML hash")
    end
  end

  context "when no start command is passed and the application does not have a procfile" do
    before { app_fixture :node_without_procfile }

    context "when the buildpack provides a default start command" do
      it_behaves_like "successful buildpack compilation"

      it "uses the default start command" do
        stage :environment => staging_env do |staged_dir|
          packages_with_start_script(staged_dir, "while :; do echo 'Running app...'; sleep 1; done")
        end
      end
    end

    context "when the buildpack does not provide a default start command" do
      let(:buildpacks_path) { buildpacks_path_without_start_cmd }

      it "raises an error " do
        expect {
          stage :environment => staging_env
        }.to raise_error("Please specify a web start command in your manifest.yml or Procfile")
      end
    end

    context "when staging an app which does not match any build packs" do
      let(:buildpacks_path) { buildpacks_path_with_no_match }

      it "raises an error" do
        expect {
          stage :environment => staging_env
        }.to raise_error("Unable to detect a supported application type")
      end
    end
  end

  context "when a rails application is detected by the ruby buildpack" do
    before { app_fixture :node_without_procfile }
    let(:buildpacks_path) { buildpacks_path_with_rails }

    it "adds rails console to the startup script" do
      stage :environment => staging_env do |staged_dir|
        packages_with_start_script(staged_dir, "bundle exec rails server --from-buildpack=true")
        expect(start_script_body(staged_dir)).to include("bundle exec ruby cf-rails-console/rails_console.rb")
      end
    end

    it "puts the necessary files in the app" do
      stage :environment => staging_env do |staged_dir|
        packages_with_start_script(staged_dir, "bundle exec rails server --from-buildpack=true")
        expect(File.exists?(File.join(staged_dir, "app", "cf-rails-console/rails_console.rb"))).to be_true
        config_file_contents = YAML.load_file(File.join(staged_dir, "app", "cf-rails-console/.consoleaccess"))
        expect(config_file_contents.keys).to match_array(["username", "password"])
      end
    end

    it "saves buildpack info" do
      stage :environment => staging_env do |_|
        expect(File.exists?(staging_info_path)).to be_true
      end
    end

    context "when a postgresql database is bound" do
      let(:staging_env) {
        <<-YAML
        services:
        - label: postgresql-5.5
          tags: {}
          name: postgres-851fd
          credentials:
            name: mariahs_db
            hostname: mariahs_host
            host: mariahs_host
            port: 5678
            user: mariah
            username: mariah
            password: nick
          options: {}
          plan: '100'
          plan_options: {}
        YAML
      }

      it "sets the DATABASE_URL in the startup script" do
        stage :environment => YAML::load(staging_env) do |staged_dir|
          start_script_body(staged_dir).should include('DATABASE_URL="postgres://mariah:nick@mariahs_host:5678/mariahs_db"')
        end
      end
    end

    context "when a rds_mysql database is bound" do
      let(:staging_env) {
        <<-YAML
        services:
        - label: rds_mysql-n/a
          tags: {}
          name: rds_mysql-851fd
          credentials:
            name: mariahs_db
            hostname: mariahs_host
            host: mariahs_host
            port: 5678
            user: mariah
            username: mariah
            password: nick
          options: {}
          plan: '10mb'
          plan_options: {}
        YAML
      }

      it "sets the DATABASE_URL in the startup script" do
        stage :environment => YAML::load(staging_env) do |staged_dir|
          start_script_body(staged_dir).should include('DATABASE_URL="mysql2://mariah:nick@mariahs_host:5678/mariahs_db"')
        end
      end
    end

    context "when a database is not bound" do
      it "does not set the DATABASE_URL in the startup script" do
        stage :environment => staging_env do |staged_dir|
          start_script_body(staged_dir).should_not include("DATABASE_URL")
        end
      end
    end
  end

  context "when a rails application is NOT detected" do
    before { app_fixture :node_without_procfile }
    let(:buildpacks_path) { buildpacks_path_with_start_cmd }

    it "doesn't add rails console to the startup script" do
      stage :environment => staging_env do |staged_dir|
        expect(start_script_body(staged_dir)).not_to include("bundle exec ruby cf-rails-console/rails_console.rb")
        expect(File.exists?(File.join(staged_dir, "cf-rails-console/rails_console.rb"))).to be_false
      end
    end
  end

  describe "#compile_with_timeout" do
    let(:duration) { 0 }

    before do
      subject.stub_chain(:build_pack, :compile) do
        sleep duration
      end
    end

    let(:staging_config) {
      {
        "source_dir" => ".",
        "dest_dir" => ".",
        "environment" => staging_env
      }
    }
    subject { Buildpacks::Buildpack.new(staging_config) }

    context "when the staging takes too long" do
      let(:duration) { 1 }

      it "times out" do
        expect {
          subject.compile_with_timeout(0.01)
        }.to raise_error(Timeout::Error)
      end
    end

    context "when the staging completes within the timeout" do
      it "does not time out" do
        expect {
          subject.compile_with_timeout(0.1)
        }.to_not raise_error
      end
    end
  end

  def start_script_body(staged_dir)
    start_script = File.join(staged_dir, 'startup')
    start_script.should be_executable_file
    File.read(start_script)
  end

  def packages_with_start_script(staged_dir, start_command)
    start_script_body(staged_dir).should include("(#{start_command}) > $DROPLET_BASE_DIR/logs/stdout.log 2> $DROPLET_BASE_DIR/logs/stderr.log &")
  end
end
