class NonBlockingUnzipper
  def unzip_to_folder(file, dest_dir, mode=0755)
    tmp_dir = Dir.mktmpdir
    File.chmod(mode, tmp_dir)
    EM.system "unzip -q #{file} -d #{tmp_dir}" do |output, status|
      if status.exitstatus == 0
        FileUtils.mv(tmp_dir, dest_dir)
      else
        tmp_dir.unlink
      end

      yield output, status.exitstatus
    end
  end
end