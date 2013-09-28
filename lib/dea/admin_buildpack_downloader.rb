require "dea/promise"
require "dea/utils/download"
require "dea/non_blocking_unzipper"

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
      dest_dir = File.join(@destination_directory, buildpack.fetch("key"))
      unless File.exists?(dest_dir)
        download_promises << Dea::Promise.new do |p|
          Download.new(buildpack.fetch("url"), @workspace, nil, logger).download! do |err, downloaded_file|
            if err
              p.deliver
            else
              tmpfile = Tempfile.new('foo').path
              FileUtils.mv(downloaded_file, tmpfile)
              NonBlockingUnzipper.new.unzip_to_folder(tmpfile, dest_dir) do
                FileUtils.rm_f(tmpfile)
                p.deliver
              end
            end
          end
        end
      end
    end
    Dea::Promise.run_in_parallel(*download_promises)
  end
end