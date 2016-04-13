require 'fileutils'

module Dea 
  def self.process_running?(pid)
    return false unless pid && (pid > 0)

    output = %x[ps -o rss= -p #{pid}]
    return true if ($? == 0 && !output.empty?)

    return false
  end

  class PidFile
    class ProcessRunningError < StandardError
    end

    def initialize(pid_file, create_parents=true)
      @pid_file = pid_file
      @dirty = true
      write(create_parents)
    end

    def unlink()
      return unless @dirty

      # Swallowing exception here is fine. Removing the pid files is a courtesy.
      begin
        File.unlink(@pid_file)
        @dirty = false
      rescue
      end
      self
    end

    def unlink_at_exit()
      at_exit { unlink() }
      self
    end

    protected

    # Atomically writes the pidfile.
    # This throws exceptions if the pidfile contains the pid of another running process.
    #
    # +create_parents+  If true, all parts of the path up to the file's dirname will be created.
    #
    def write(create_parents=true)
      FileUtils.mkdir_p(File.dirname(@pid_file)) if create_parents

      # Closing the fd as the block finishes releases our lock
      File.open(@pid_file, 'a+b', 0644) do |f|
        f.flock(File::LOCK_EX)

        # Check if process is already running
        pid = f.read().strip().to_i()
        if pid == Process.pid()
          return
        elsif Dea.process_running?(pid)
          raise ProcessRunningError.new("Process already running (pid=%d)." % (pid))
        end

        f.truncate(0)
        f.rewind()
        f.write("%d\n" % (Process.pid()))
        f.flush()
      end
    end
  end
end 
