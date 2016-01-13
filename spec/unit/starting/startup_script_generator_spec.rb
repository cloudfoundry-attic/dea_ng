require "spec_helper"
require "dea/starting/startup_script_generator"

describe Dea::StartupScriptGenerator do
  let(:user_envs) { %Q{export usr1="usrval1";\nexport usr2="usrval2";\nunset unset_var;\n} }
  let(:system_envs) { %Q{export usr1="sys_user_val1";\nexport sys1="sysval1";\n} }
  let(:used_buildpack) { '' }
  let(:start_command) { "go_nuts 'man' ; echo 'wooooohooo'" }
  let(:post_setup_hook) { "command1; command2" }

  let(:generator) { Dea::StartupScriptGenerator.new(start_command, user_envs, system_envs, post_setup_hook) }

  describe "#generate" do
    subject(:script) { generator.generate }

    describe "umask" do
      it "sets the umask to 077" do
        expect(script).to include "umask 077"
      end
    end

    describe "environment variables" do
      it "exports the user env variables" do
        expect(script).to include user_envs
      end

      it "exports the system env variables" do
        expect(script).to include system_envs
      end

      it "sources the buildpack env variables" do
        expect(script).to include "in app/.profile.d/*.sh"
        expect(script).to include ". $i"
      end

      it "exports user variables after system variables" do
        expect(script).to match /usr1="sys_user_val1".*usr1="usrval1"/m
      end

      it "exports build pack variables after system variables" do
        expect(script).to match /"sysval1".*\.profile\.d/m
      end

      it "exports build pack variables after user variables" do
        expect(script).to match /usrval1.*\.profile\.d/m
      end
    end

    describe "starting app" do
      it "includes the escaped start command in the starting script" do
        expect(script).to include(described_class::START_SCRIPT % Shellwords.shellescape(start_command))
      end
    end

    describe "post setup hook" do
      it "includes the escaped setup hook" do
        expect(script).to include("command1; command2")
      end

      context "when nil" do
        let(:post_setup_hook) { nil }

        it "does not include garbage " do
          expect(script).not_to include("''")
        end
      end

      context "when empty string" do
        let(:post_setup_hook) { '' }

        it "does not include garbage " do
          expect(script).not_to include("''")
        end
      end
    end
  end
end
