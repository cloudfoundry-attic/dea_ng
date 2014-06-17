class NonBlockingUnzipper
  def unzip_to_folder(file, dest_dir, mode=0755)
    tmp_dir = Dir.mktmpdir
    File.chmod(mode, tmp_dir)
    EM.system "unzip -q #{file} -d #{tmp_dir}" do |output, status|
      if status.exitstatus == 0
        move_atomically(tmp_dir, dest_dir)
      else
        tmp_dir.unlink
      end

      yield output, status.exitstatus
    end
  end

  private

  def move_atomically(from_dir, dest_dir)
    tmp_dest_dir = File.join(File.dirname(dest_dir), File.basename(dest_dir) + "-moving")

    begin
      FileUtils.mv(from_dir, tmp_dest_dir)
      File.rename(tmp_dest_dir, dest_dir)
    rescue => e
      ## If the move fails half-way (which can happen when
      ## moving between filesystems) we'll be left with a
      ## directory named [guid]-moving, we'll try to clean
      ## this up here, but if it fails it should only result
      ## in some unnecesarily used disk-space until the next
      ## download for the same [guid] happens
      FileUtils.rm_rf(tmp_dest_dir)
    end
  end
end
