require "dea/promise"
require "dea/utils/download"
require "dea/utils/non_blocking_unzipper"
require "em-synchrony/thread"

class AdminBuildpackDownloader
  attr_reader :logger

  DOWNLOAD_MUTEX = EventMachine::Synchrony::Thread::Mutex.new
  MAX_DOWNLOAD_ATTEMPTS = 3

  def initialize(buildpacks, destination_directory, custom_logger=nil)
    @buildpacks = buildpacks
    @destination_directory = destination_directory
    @logger = custom_logger || self.class.logger
  end

  def download
    logger.debug("admin-buildpacks.download", buildpacks: @buildpacks)
    return unless @buildpacks

    FileUtils.mkdir_p(@destination_directory)
    DOWNLOAD_MUTEX.synchronize do
      @buildpacks.each do |buildpack|
        attempts = 0
        success = false

        dest_dir = File.join(@destination_directory, buildpack.fetch(:key))
        unless File.exists?(dest_dir)
          until success
            begin
              attempts += 1
              download_one_buildpack(buildpack, dest_dir).resolve
              success = true
            rescue Download::DownloadError => e
              raise e if attempts >= MAX_DOWNLOAD_ATTEMPTS
            end
          end
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
