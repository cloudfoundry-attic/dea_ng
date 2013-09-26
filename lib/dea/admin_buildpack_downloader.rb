require "dea/promise"
require "dea/utils/download"

class AdminBuildpackDownloader
  attr_reader :logger

  def initialize(buildpacks, destination_directory, workspace, custom_logger=nil)
    @buildpacks = buildpacks
    @destination_directory = destination_directory
    @workspace = workspace
    @logger = custom_logger || self.class.logger
  end

  def download
    logger.debug "Downloading buildpacks #{@buildpacks}"
    return unless @buildpacks
    download_promises = []
    @buildpacks.each do |buildpack|
      target_file_path = File.join(@destination_directory, buildpack.fetch("key"))
      unless File.exists?(target_file_path)
        download_promises << Dea::Promise.new do |p|
          Download.new(buildpack.fetch("url"), @workspace, nil, logger).download! do |err, downloaded_file|
            unzip_to_destination(downloaded_file, target_file_path) unless err
            p.deliver
          end
        end
      end
    end
    Dea::Promise.run_in_parallel(*download_promises)
  end

  private
  def unzip_to_destination(path, target_file_path)
    tmp_dir = Dir.mktmpdir(nil, @workspace)
    File.chmod(0755, tmp_dir)
    system "unzip -q #{path} -d #{tmp_dir}"
    File.rename(tmp_dir, target_file_path)
  ensure
    FileUtils.rm_f(tmp_dir) if File.exists?(tmp_dir)
  end
end