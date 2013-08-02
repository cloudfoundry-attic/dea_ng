require "spec_helper"
require "dea/starting/startup_script_generator"

describe Dea::StartupScriptGenerator do
  let(:user_envs) { [["usr1", "'usrval1'"], ["usr2", "'usrval2'"], ["unset_var", nil]] }
  let(:system_envs) { [["usr1", "'sys_user_val1'"], ["sys1", "'sysval1'"]] }
  let(:used_buildpack) { '' }
  let(:start_command) { 'go_nuts' }

  let(:generator) { Dea::StartupScriptGenerator.new(start_command, user_envs, system_envs, used_buildpack) }

  describe "#generate" do
    subject(:script) { generator.generate }

    describe "umask" do
      it "sets the umask to 077" do
        script.should include "umask 077"
      end
    end

    describe "environment variables" do
      it "exports the user env variables" do
        script.should include "export usr1='usrval1';"
        script.should include "export usr2='usrval2';"
      end

      it "unsets any blank user variables" do
        script.should include "unset unset_var;"
      end

      it "exports the system env variables" do
        script.should include "export usr1='sys_user_val1';"
        script.should include "export sys1='sysval1';"
      end

      it "sources the buildpack env variables" do
        script.should include "in app/.profile.d/*.sh"
        script.should include ". $i"
      end

      it "exports user variables after system variables" do
        script.should match /usr1='sys_user_val1'.*usr1='usrval1'/m
      end

      it "exports build pack variables after system variables" do
        script.should match /'sysval1'.*\.profile\.d/m
      end

      it "sets user variables after buildpack variables" do
        script.should match /\.profile\.d.*usrval1/m
      end

      it "print env to a log file after user envs" do
        script.should include "env > logs/env.log"
        script.should match /usrval1.*env\.log/m
      end
    end

    describe "rails console script" do
      context "when a Rails builpack was used" do
        let(:used_buildpack) { 'Ruby/Rails' }
        it "includes the rails console section" do
          script.should include described_class::RAILS_CONSOLE_SCRIPT
        end
      end

      context "for a non Rails build pack" do
        let(:used_buildpack) { 'JS/Node' }
        it "does not include the rails console section" do
          script.should_not include described_class::RAILS_CONSOLE_SCRIPT
        end
      end
    end

    describe "starting app" do
      it "includes the start command in the starting script" do
        script.should include described_class::START_SCRIPT % start_command
      end
    end
  end
end
