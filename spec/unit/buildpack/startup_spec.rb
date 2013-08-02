require 'spec_helper'

describe "startup" do
  let(:user_envs) { "export USR='foo';" }
  let(:system_envs) { "export SYS='foo';" }
  let(:used_buildpack) { "JS/Node" }
  let(:command) { "env" }

  subject do
    startup_script = File.expand_path("../../../../buildpacks/lib/resources/startup", __FILE__)
    %x[#{startup_script} "#{command}" "#{user_envs}" "#{system_envs}" "#{used_buildpack}"]
  end

  before do
    FileUtils.mkdir_p "app"
    FileUtils.mkdir_p "logs"
  end

  after do
    FileUtils.rm_rf "app"
    FileUtils.rm_rf "logs"
  end


  describe "#export_buildpack_env_variables" do

  end

  describe "#run_rails_console" do

  end

  describe "#start_app" do

  end
end