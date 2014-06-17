require "dea/promise"
require "dea/utils/download"
require "dea/utils/non_blocking_unzipper"
require "em-synchrony/thread"

class AdminBuildpackDownloader
  attr_reader :logger

  DOWNLOAD_MUTEX = EventMachine::Synchrony::Thread::Mutex.new

  def initialize(buildpacks, destination_directory, custom_logger=nil)
    @buildpacks = buildpacks
    @destination_directory = destination_directory
    @logger = custom_logger || self.class.logger
  end

  def download
    logger.debug("admin-buildpacks.download", buildpacks: @buildpacks)
    return unless @buildpacks

    DOWNLOAD_MUTEX.synchronize do
      @buildpacks.each do |buildpack|
        dest_dir = File.join(@destination_directory, buildpack.fetch(:key))
        unless File.exists?(dest_dir)
          download_one_buildpack(buildpack, dest_dir).resolve
        end
      end
    end
  end

  private

  def download_one_buildpack(buildpack, dest_dir)
    Dea::Promise.new do |p|
      tmpfile = Tempfile.new('temp_admin_buildpack')

      Download.new(buildpack.fetch(:url), tmpfile, nil, logger).download! do |err|
        if err
          p.fail err
        else
          NonBlockingUnzipper.new.unzip_to_folder(tmpfile.path, dest_dir) do |output, status|
            tmpfile.unlink
            if status == 0
              p.deliver
            else
              p.fail output
            end
          end
        end
      end
    end
  end
end