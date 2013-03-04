require 'tmpdir'

module StagingSpecHelpers

  # Importantly, this returns a Pathname instance not a String.
  # This allows you to write: app_fixture_base_directory.join('subdir', 'subsubdir')
  def app_fixture_base_directory
    Pathname.new(File.expand_path('../../fixtures/apps', __FILE__))
  end

  # Set the app fixture that the current spec will use.
  # TODO - Ensure that this is is cleared between groups.
  def app_fixture(name)
    @app_fixture = name.to_s
  end

  def app_source(tempdir = nil)
    unless @app_fixture
      raise "Call 'app_fixture :name_of_app' before using app_source"
    end
    app_dir = app_fixture_base_directory.join(@app_fixture)
    if File.exist?(warfile = app_dir.join('source.war'))
      # packaged WAR file
      tempdir ||= Dir.mktmpdir(@app_fixture)
      output = `unzip -q #{warfile} -d #{tempdir} 2>&1`
      unless $? == 0
        raise "Failed to unpack #{@app_fixture} WAR file: #{output}"
      end
      tempdir.to_s
    else
      # exploded directory
      app_dir.join('source').to_s
    end
  end

  # If called without a block, returns the staging output directory as a string.
  # You must manually clean up the directory thus created.
  # If called with a block, yields the staged directory as a Pathname, and
  # automatically deletes it when the block returns.
  def stage(env = {})
    raise "Call 'app_fixture :name_of_app' before staging" unless @app_fixture
    plugin_klass = Buildpacks::Buildpack
    working_dir = Dir.mktmpdir("#{@app_fixture}-staged")
    source_tempdir = nil
    source_dir = app_source
    env[:environment] ||= []
    stager = plugin_klass.new(source_dir, working_dir, env)
    stager.stage_application
    return working_dir unless block_given?
    Dir.chdir(working_dir) do
      yield Pathname.new(working_dir), Pathname.new(source_dir)
    end
    nil
  ensure
    FileUtils.rm_r(working_dir) if working_dir
    FileUtils.rm_r(source_tempdir) if source_tempdir
  end
end