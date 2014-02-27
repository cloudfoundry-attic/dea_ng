# coding: UTF-8

require "tmpdir"

shared_context "tmpdir" do
  attr_reader :tmpdir

  around do |example|
    tmpdir = Dir.mktmpdir
    @tmpdir = File.realpath(tmpdir)
    begin
      example.run
    ensure
      begin
        FileUtils.remove_entry_secure tmpdir
      rescue Errno::EACCES
        # Windows won't let you delete directories that are in use.
        # Ignore these errors.
      end
    end
  end
end
