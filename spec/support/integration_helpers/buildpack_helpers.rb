require "socket"

module BuildpackHelpers
  def fake_buildpack_url(buildpack_name)
    "http://#{file_server_address}/buildpacks/#{buildpack_name}/.git"
  end

  def setup_fake_buildpack(buildpack_name)
    Dir.chdir("spec/fixtures/fake_buildpacks/#{buildpack_name}") do
      `rm -rf .git`
      `git init`
      `git add . && git add -A`
      `git commit -am "fake commit"`
      `git branch a_branch`
      `git tag -m 'annotated tag' a_tag`
      `git tag a_lightweight_tag`
      `git update-server-info`
    end
  end

  def download_tgz(url)
    Dir.mktmpdir do |dir|
      `curl --silent --show-error #{url} > #{dir}/staged_app.tgz`
      `cd #{dir} && tar xzf staged_app.tgz`
      yield dir
    end
  end
end
