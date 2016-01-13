require "spec_helper"
require "dea/starting/startup_script_generator"

describe Dea::StartupScriptGenerator do
  let(:user_envs) { %Q{export usr1="usrval1";\nexport usr2="usrval2";\nunset unset_var;\n} }
  let(:system_envs) { %Q{export usr1="sys_user_val1";\nexport sys1="sysval1";\n} }
  let(:used_buildpack) { '' }
  let(:start_command) { "go_nuts 'man' ; echo 'wooooohooo'" }

  let(:generator) { Dea::StartupScriptGenerator.new(start_command, user_envs, system_envs) }

  describe "#generate" do
    subject(:script) { generator.generate }

    describe "umask" do
      it "sets the umask to 077" do
        script.should include "umask 077"
      end
    end

    describe "environment variables" do
      it "exports the user env variables" do
        script.should include user_envs
      end

      it "exports the system env variables" do
        script.should include system_envs
      end

      it "sources the buildpack env variables" do
        script.should include "in app/.profile.d/*.sh"
        script.should include ". $i"
      end

      it "exports user variables after system variables" do
        script.should match /usr1="sys_user_val1".*usr1="usrval1"/m
      end

      it "exports build pack variables after system variables" do
        script.should match /"sysval1".*\.profile\.d/m
      end

      it "exports build pack variables after user variables" do
        script.should match /usrval1.*\.profile\.d/m
      end
    end

    describe "starting app" do
      it "includes the escaped start command in the starting script" do
        expect(script).to include(described_class::START_SCRIPT % Shellwords.shellescape(start_command))
      end
    end
  end
end
