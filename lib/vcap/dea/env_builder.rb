require 'json'
require 'logger'

module VCAP module Dea end end

class VCAP::Dea::EnvBuilder
  def initialize(runtimes, local_ip, logger = nil)
    @logger = logger || Logger.new(STDOUT)
    @runtimes = runtimes
    @local_ip= local_ip
  end

  # The format used by VCAP_SERVICES
  def create_services_for_env(services=[])
    whitelist = ['name', 'label', 'plan', 'tags', 'plan_option', 'credentials']
    svcs_hash = {}
    services.each do |svc|
      svcs_hash[svc['label']] ||= []
      svc_hash = {}
      whitelist.each {|k| svc_hash[k] = svc[k] if svc[k]}
      svcs_hash[svc['label']] << svc_hash
    end
    svcs_hash.to_json
  end

  # The format used by VMC_SERVICES
  def create_legacy_services_for_env(services=[])
    whitelist = ['name', 'type', 'vendor', 'version']
    as_legacy = services.map do |svc|
      leg_svc = {}
      whitelist.each {|k| leg_svc[k] = svc[k] if svc[k]}
      leg_svc['tier'] = svc['plan']
      leg_svc['options'] = svc['credentials']
      leg_svc
    end
    as_legacy.to_json
  end

  # The format used by VCAP_APP_INSTANCE
  def create_instance_for_env(instance)
    whitelist = [:instance_id, :instance_index, :name, :uris, :users, :version, :start, :runtime, :state_timestamp, :port]
    env_hash = {}
    whitelist.each {|k| env_hash[k] = instance[k] if instance[k]}
    env_hash[:limits] = {
      :fds  => instance[:fds_quota],
      :mem  => instance[:mem_quota],
      :disk => instance[:disk_quota],
    }
    env_hash[:host] = @local_ip
    env_hash.to_json
  end

  def debug_env(instance)
    return unless instance[:debug_port]
    return unless envs = @runtimes[instance[:runtime]]['debug_env']
    envs[instance[:debug_mode]]
  end

  def runtime_env(runtime_name)
    env = []
    if runtime_name && runtime = @runtimes[runtime_name]
      if re = runtime['environment']
        re.each { |k,v| env << "#{k}=#{v}"}
      end
    end
    env
  end

  def setup_instance_env(instance, app_env, services)
    env = []

    env << "HOME=#{instance[:dir]}"
    env << "VCAP_APPLICATION='#{create_instance_for_env(instance)}'"
    env << "VCAP_SERVICES='#{create_services_for_env(services)}'"
    env << "VCAP_APP_HOST='#{@local_ip}'"
    env << "VCAP_APP_PORT='#{instance[:port]}'"
    env << "VCAP_DEBUG_IP='#{instance[:debug_ip]}'"
    env << "VCAP_DEBUG_PORT='#{instance[:debug_port]}'"
    env << "VCAP_CONSOLE_IP='#{instance[:console_ip]}'"
    env << "VCAP_CONSOLE_PORT='#{instance[:console_port]}'"

    if vars = debug_env(instance)
      @logger.info("Debugger environment variables: #{vars.inspect}")
      env += vars
    end

    # LEGACY STUFF
    env << "VMC_WARNING_WARNING='All VMC_* environment variables are deprecated, please use VCAP_* versions.'"
    env << "VMC_SERVICES='#{create_legacy_services_for_env(services)}'"
    env << "VMC_APP_INSTANCE='#{instance.to_json}'"
    env << "VMC_APP_NAME='#{instance[:name]}'"
    env << "VMC_APP_ID='#{instance[:instance_id]}'"
    env << "VMC_APP_VERSION='#{instance[:version]}'"
    env << "VMC_APP_HOST='#{@local_ip}'"
    env << "VMC_APP_PORT='#{instance[:port]}'"

    services.each do |service|
      hostname = service['credentials']['hostname'] || service['credentials']['host']
      port = service['credentials']['port']
      env << "VMC_#{service['vendor'].upcase}=#{hostname}:#{port}"  if hostname && port
    end

    # Do the runtime environment settings
    runtime_env(instance[:runtime]).each { |re| env << re }

    # User's environment settings
    # Make sure user's env variables are in double quotes.
    if app_env
      app_env.each do |ae|
        k,v = ae.split('=', 2)
        v = "\"#{v}\"" unless v.start_with? "'"
        env << "#{k}=#{v}"
      end
    end
    return env
  end
end
