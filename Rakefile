require "rspec/core/rake_task"
require "rspec/core/version"

desc "Run all examples"
RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = %w[--color --format documentation]
end

desc "Run (or re-run) to setup dea"
task :setup do
  sh "cd nginx ; ./build.sh"
end
