# coding: UTF-8

require "rspec/core/rake_task"
require "rspec/core/version"

desc "Run all examples"
RSpec::Core::RakeTask.new(:spec) do |t|
  # See .rspec
end

task :ensure_coding do
  patterns = [
    /Rakefile$/,
    /\.rb$/,
  ]

  files = `git ls-files`.split.select do |file|
    patterns.any? { |e| e.match(file) }
  end

  header = "# coding: UTF-8\n\n"

  files.each do |file|
    content = File.read(file)

    unless content.start_with?(header)
      File.open(file, "w") do |f|
        f.write(header)
        f.write(content)
      end
    end
  end
end

namespace :config do
  desc "Check if configuration file is valid"
  task :check, :file do |t, args|
    require "yaml"
    require "dea/config"

    config = YAML.load(File.read(args[:file]))
    Dea::Config.schema.validate(config)
  end
end
