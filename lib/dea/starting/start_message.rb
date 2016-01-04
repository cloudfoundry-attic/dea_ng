class StartMessage
  def initialize(message)
    @message = message
  end

  def to_hash
    message
  end

  def index
    message["index"]
  end

  def droplet
    message["droplet"]
  end

  def version
    message["version"]
  end

  def name
    message["name"]
  end

  def uris
    (message["uris"] || []).map { |uri| URI(uri) }
  end

  def executable_uri
    URI(message["executableUri"]) if message["executableUri"]
  end

  def cc_partition
    message["cc_partition"]
  end

  def vcap_application
    message["vcap_application"] || {}
  end

  def limits
    message["limits"] || {}
  end

  def mem_limit
    limits["mem"]
  end

  def disk_limit
    limits["disk"]
  end

  def fds_limit
    limits["fds"]
  end

  def start_command
    message["start_command"]
  end

  def services
    message["services"] || []
  end

  def debug
    !!message["debug"]
  end

  def sha1
    message["sha1"]
  end

  def console
    !!message["console"]
  end

  def executable_file
    message["executableFile"]
  end

  def env
    message["env"] || []
  end

  def egress_network_rules
    message["egress_network_rules"] || []
  end

  def stack
    message["stack"]
  end

  def message
    @message || {}
  end
end
