require "dea/promise"
require "dea/utils/download"
require "dea/utils/non_blocking_unzipper"

class AdminBuildpackDownloader
  attr_reader :logger

  def initialize(buildpacks, destination_directory, custom_logger=nil)
    @buildpacks = buildpacks
    @destination_directory = destination_directory
    @logger = custom_logger || self.class.logger
  end

  def download
    logger.debug "admin-buildpacks.download", buildpacks: @buildpacks
    return unless @buildpacks

    download_promises = []
    @buildpacks.each do |buildpack|
      dest_dir = File.join(@destination_directory, buildpack.fetch(:key))
      unless File.exists?(dest_dir)
        download_promises << download_one_buildpack(buildpack, dest_dir)
      end
    end

    Dea::Promise.run_in_parallel(*download_promises)
  end

  private

  def download_one_buildpack(buildpack, dest_dir)
    Dea::Promise.new do |p|
      tmpfile = Tempfile.new('temp_admin_buildpack')

      Download.new(buildpack.fetch(:url), tmpfile, nil, logger).download! do |err|
        if err
          p.deliver
        else
          NonBlockingUnzipper.new.unzip_to_folder(tmpfile.path, dest_dir) do
            tmpfile.unlink
            p.deliver
          end
        end
      end
    end
  end
end