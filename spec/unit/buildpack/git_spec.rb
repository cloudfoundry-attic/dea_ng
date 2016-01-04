require "spec_helper"

describe Buildpacks::Git, type: :buildpack do
  let(:simple_url) { "git://github.com/heroku/heroku-buildpack-java.git" }
  let(:branch) {"my-branch"}
  let(:url_with_branch) { "git://github.com/heroku/heroku-buildpack-java.git##{branch}" }
  let(:destination) { '/tmp/buildpacks' }

  describe "#parse" do
    it "parses a git url" do
      url, branch = Buildpacks::Git.parse(simple_url)

      expect(url).to eql(URI.parse(simple_url))
      expect(branch).to be_nil
    end

    it "parses the branch of a git url" do
      url, branch = Buildpacks::Git.parse(url_with_branch)

      expect(url).to eql(URI.parse(simple_url))
      expect(branch).to eql(branch)
    end

    it "fails with invalid git urls" do
      expect {
        url, branch = Buildpacks::Git.parse("http://user:pass;2wo#rd@github.com/cf/buildpack-java.git?a=b&c=d")
      }.to raise_error(URI::InvalidURIError)
    end

    it "parses including escaped characters" do
      userinfo = URI.escape("user:passw#rd")
      url, branch = Buildpacks::Git.parse("http://#{userinfo}@github.com/cf/buildpack-java.git")

      expect(url).to eql(URI.parse("http://#{userinfo}@github.com/cf/buildpack-java.git"))
      expect(branch).to be_nil
    end
  end

  describe "#clone" do
    it "clones a URL" do
      allow(Buildpacks::Git).to receive(:system)
        .with(*"git clone --depth 1 --recursive #{simple_url} /tmp/buildpacks/heroku-buildpack-java".split)
        .and_return(true)

      git_dir = Buildpacks::Git.clone(simple_url, destination)

      expect(git_dir).to eql("#{destination}/heroku-buildpack-java")
    end

    it "clones a URL with a branch" do
      allow(Buildpacks::Git).to receive(:system)
        .with(*"git clone --depth 1 -b #{branch} --recursive #{simple_url} /tmp/buildpacks/heroku-buildpack-java".split)
        .and_return(true)

      Buildpacks::Git.clone(url_with_branch, destination)
    end

    it "clones a URL with a lighweight tag" do
      allow(Buildpacks::Git).to receive(:system)
        .with(*"git clone --depth 1 -b #{branch} --recursive #{simple_url} /tmp/buildpacks/heroku-buildpack-java".split)
        .and_return(false)
      allow(Buildpacks::Git).to receive(:system)
        .with(*"git clone --recursive #{simple_url} /tmp/buildpacks/heroku-buildpack-java".split)
        .and_return(true)
      allow(Buildpacks::Git).to receive(:checkout)
        .with(branch, "#{destination}/heroku-buildpack-java")
        .and_return(true)

      Buildpacks::Git.clone(url_with_branch, destination)
    end

    context "when the deep cloning fails" do
      it "raises an error" do
        allow(Buildpacks::Git).to receive(:system)
          .with(*"git clone --depth 1 -b #{branch} --recursive #{simple_url} /tmp/buildpacks/heroku-buildpack-java".split)
          .and_return(false)

        cmd = "git clone --recursive #{simple_url} /tmp/buildpacks/heroku-buildpack-java"
        allow(Buildpacks::Git).to receive(:system)
          .with(*cmd.split)
          .and_return(false)

        expect {
          Buildpacks::Git.clone(url_with_branch, destination)
        }.to raise_error("Git clone failed: #{cmd}")
      end
    end
  end

  describe "#checkout" do
    let(:git_dir) { "#{destination}/heroku-buildpack-java"}

    it "performs a checkout" do
      allow(Buildpacks::Git).to receive(:system)
        .with(*"git --git-dir=#{git_dir}/.git --work-tree=#{git_dir} checkout #{branch}".split)
        .and_return(true)

        Buildpacks::Git.checkout(branch, git_dir)
    end

    context "when checkout fails" do
      it "raises an error" do
        cmd = "git --git-dir=#{git_dir}/.git --work-tree=#{git_dir} checkout #{branch}"
        allow(Buildpacks::Git).to receive(:system)
          .with(*cmd.split)
          .and_return(false)

        expect {
          Buildpacks::Git.checkout(branch, git_dir)
        }.to raise_error("Git checkout failed: #{cmd}")
      end
    end
  end
end
