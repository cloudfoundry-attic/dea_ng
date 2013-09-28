class NonBlockingUnzipper
  def unzip_to_folder(file, dest_dir, mode=0755)
    tmp_dir = Dir.mktmpdir
    File.chmod(mode, tmp_dir)
    EM.system "unzip -q #{file} -d #{tmp_dir}" do
      FileUtils.mv(tmp_dir, dest_dir)
      yield
    end
  end
end