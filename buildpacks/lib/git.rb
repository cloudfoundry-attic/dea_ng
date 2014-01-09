require "uri"

module Buildpacks
  class Git
    def self.parse(repository)
      parsed = URI(repository)
      branch = parsed.fragment if parsed.fragment
      parsed.fragment = nil
      return parsed, branch
    end

    def self.clone(repository, destination)
      git_url, branch = parse(repository)
      target_dir = File.join(destination, File.basename(git_url.path, File.extname(git_url.path)))

      git_branch_option = branch.to_s.empty? ? "" : "-b #{branch}"
      cmd = "git clone --depth 1 #{git_branch_option} --recursive #{git_url} #{target_dir}"
      ok = system(*cmd.split)

      if !ok
        cmd = "git clone --recursive #{git_url} #{target_dir}"
        ok = system(*cmd.split)
        raise "Git clone failed: #{cmd}" unless ok
        checkout(branch, target_dir) if branch
      end

      target_dir
    end

    def self.checkout(branch, git_dir)
      cmd = "git --git-dir=#{git_dir}/.git --work-tree=#{git_dir} checkout #{branch}"
      ok = system(*cmd.split)
      raise "Git checkout failed: #{cmd}" unless ok
    end
  end
end
