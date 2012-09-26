# coding: UTF-8

require "tmpdir"

shared_context "tmpdir" do
  attr_reader :tmpdir

  around do |example|
    Dir.mktmpdir do |tmpdir|
      # Store path to tmpdir
      @tmpdir = File.realpath(tmpdir)

      # Run example
      example.run
    end
  end
end
