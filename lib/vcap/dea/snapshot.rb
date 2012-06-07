require 'logger'
require 'yajl'
require 'pp'
require 'json'

module VCAP module Dea end end

class VCAP::Dea::Snapshot
  APP_STATE_FILE = 'applications.json'

  def initialize(db_dir, logger = nil)
    @logger = logger || Logger.new(STDOUT)
    @db_dir = db_dir
    @app_state_file = File.join(@db_dir, APP_STATE_FILE)
    @logger.debug("snapshotter initialized")
  end

  def store_snapshot(app_state)
    start = Time.now
    tmp = File.new("#{@db_dir}/snap_#{Time.now.to_i}", 'w')
    #XXX why are we writing out with JSON instead of yajl?
    tmp.puts(JSON.pretty_generate(app_state))
    tmp.close
    FileUtils.mv(tmp.path, @app_state_file)
    @logger.debug("commited #{tmp.path} to #{@app_state_file}")
    @logger.debug("Took #{Time.now - start} to snapshot application state.")
  end

  def read_snapshot
    unless File.exists?(@app_state_file)
      @logger.info "No previous snapshot found"
      return nil
    end
    recovered = nil
    File.open(@app_state_file, 'r') { |f| recovered = Yajl::Parser.parse(f) }
    recovered
  end
end

