module BuildpackHelpers
  def fake_buildpack_url(buildpack_name)
    "http://#{hostname}:9999/buildpacks/#{buildpack_name}/.git"
  end

  def setup_fake_buildpack(buildpack_name)
    Dir.chdir("spec/fixtures/fake_buildpacks/#{buildpack_name}") do
      `rm -rf .git`
      `git init`
      `git add . && git add -A`
      `git commit -am "fake commit"`
      `git update-server-info`
    end
  end

  private

  def hostname
    `hostname -I`.split(" ")[0]
  end
end
