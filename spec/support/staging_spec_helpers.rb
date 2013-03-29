require 'tmpdir'

module StagingSpecHelpers
  def app_fixture(name)
    @app_fixture = name.to_s
  end

  def stage(env = {})
    raise "Call 'app_fixture :name_of_app' before staging" unless @app_fixture
    working_dir = Dir.mktmpdir("#{@app_fixture}-staged")
    env["environment"] ||= []
    Buildpacks::Buildpack.new(app_source, working_dir, env).stage_application
    Dir.chdir(working_dir) do
      yield Pathname.new(working_dir) if block_given?
    end
  ensure
    FileUtils.rm_r(working_dir) if working_dir
  end

  private

  def app_fixture_base_directory
    Pathname.new(File.expand_path('../../fixtures/apps', __FILE__))
  end

  def app_source
    app_fixture_base_directory.join(@app_fixture).to_s
  end
end