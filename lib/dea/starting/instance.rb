# coding: UTF-8

require 'membrane'
require 'steno'
require 'steno/core_ext'
require 'vcap/common'
require 'yaml'

require 'dea/env'
require 'dea/health_check/port_open'
require 'dea/health_check/state_file_ready'
require 'dea/promise'
require 'dea/stat_collector'
require 'dea/task'
require 'dea/utils/event_emitter'
require 'dea/starting/startup_script_generator'
require 'dea/user_facing_errors'

module Dea
  class Instance < Task
    include EventEmitter

    STAT_COLLECTION_INTERVAL_SECS = 10
    NPROC_LIMIT = 512

    class State
      BORN = 'BORN'
      STARTING = 'STARTING'
      RUNNING = 'RUNNING'
      STOPPING = 'STOPPING'
      STOPPED = 'STOPPED'
      CRASHED = 'CRASHED'
      RESUMING = 'RESUMING'
      EVACUATING = 'EVACUATING'

      def self.from_external(state)
        case state.upcase
          when 'BORN'
            BORN
          when 'STARTING'
            STARTING
          when 'RUNNING'
            RUNNING
          when 'STOPPING'
            STOPPING
          when 'STOPPED'
            STOPPED
          when 'CRASHED'
            CRASHED
          when 'RESUMING'
            RESUMING
          when 'EVACUATING'
            EVACUATING
          else
            raise "Unknown state: #{state}"
        end
      end

      def self.to_external(state)
        case state
          when Dea::Instance::State::BORN
            'BORN'
          when Dea::Instance::State::STARTING
            'STARTING'
          when Dea::Instance::State::RUNNING
            'RUNNING'
          when Dea::Instance::State::STOPPING
            'STOPPING'
          when Dea::Instance::State::STOPPED
            'STOPPED'
          when Dea::Instance::State::CRASHED
            'CRASHED'
          when Dea::Instance::State::RESUMING
            'RESUMING'
          when Dea::Instance::State::EVACUATING
            'EVACUATING'
          else
            raise "Unknown state: #{state}"
        end
      end
    end

    class Transition < Struct.new(:from, :to)
      def initialize(*args)
        super(*args.map(&:to_s).map(&:downcase))
      end
    end

    class TransitionError < BaseError
      attr_reader :from
      attr_reader :to

      def initialize(from, to = nil)
        @from = from
        @to = to
      end

      def to_s
        parts = []
        parts << 'Cannot transition from %s' % [from.inspect]

        if to
          parts << 'to %s' % [to.inspect]
        end

        parts.join(' ')
      end
    end

    class AttributesLoggingFilter
      FILTER = %w[services environment droplet_uri]

      def initialize(attributes)
        @attributes = attributes
      end

      def to_hash
        attributes = @attributes.dup
        attributes.delete_if do |key,value|
          FILTER.include?(key)
        end

        attributes
      end

      def to_json
        to_hash.to_json
      end
    end

    def self.translate_attributes(attributes)
      attributes = attributes.dup

      transfer_attr_with_existance_check(attributes, 'instance_index', 'index')
      transfer_attr_with_existance_check(attributes, 'application_version', 'version')
      transfer_attr_with_existance_check(attributes, 'application_name', 'name')
      transfer_attr_with_existance_check(attributes, 'application_uris', 'uris')

      attributes['application_id'] ||= attributes.delete('droplet').to_s if attributes['droplet']
      attributes['droplet_sha1'] ||= attributes.delete('sha1')
      attributes['droplet_uri'] ||= attributes.delete('executableUri')

      # Translate environment to dictionary (it is passed as Array with VAR=VAL)
      env = attributes.delete('env') || []
      attributes['environment'] ||= Hash[env.map do |e|
        pair = e.split('=', 2)
        pair[0] = pair[0].to_s
        pair[1] = pair[1].to_s
        pair
      end]

      attributes
    end

    def self.transfer_attr_with_existance_check(attr, new_key, old_key)
      attr[new_key] ||= attr.delete(old_key) if attr[old_key]
    end

    def self.limits_schema
      Membrane::SchemaParser.parse do
        {
          'mem' => Fixnum,
          'disk' => Fixnum,
          'fds' => Fixnum,
        }
      end
    end

    def self.service_schema
      Membrane::SchemaParser.parse do
        {
          'name' => String,
          'label' => String,
          'credentials' => any,

          # Deprecated fields
          optional('plan') => String,
          optional('vendor') => String,
          optional('version') => String,
          optional('type') => String,
          optional('plan_option') => enum(String, nil),
        }
      end
    end

    def self.schema
      limits_schema = self.limits_schema
      service_schema = self.service_schema

      Membrane::SchemaParser.parse do
        {
          # Static attributes (coming from cloud controller):
          'cc_partition' => String,

          'instance_id' => String,
          'instance_index' => Integer,

          'application_id' => String,
          'application_version' => String,
          'application_name' => String,
          'application_uris' => [String],

          'droplet_sha1' => enum(nil, String),
          'droplet_uri' => enum(nil, String),

          optional('start_command') => enum(nil, String),

          optional('warden_handle') => enum(nil, String),
          optional('instance_host_port') => Integer,
          optional('instance_container_port') => Integer,

          'limits' => limits_schema,

          'environment' => dict(String, String),
          'services' => [service_schema],

          # private_instance_id is internal id that represents the instance,
          # which is generated by DEA itself. Currently, we broadcast it to
          # all routers. Routers use that as sticky session of the instance.
          'private_instance_id' => String,
        }
      end
    end

    # Define an accessor for every attribute with a schema
    self.schema.schemas.each do |key, _|
      define_method(key) do
        attributes[key]
      end
    end

    def self.define_state_methods(state)
      state_predicate = "#{state.to_s.downcase}?"
      define_method(state_predicate) do
        self.state == state
      end

      state_time = "state_#{state.to_s.downcase}_timestamp"
      define_method(state_time) do
        attributes[state_time]
      end
    end

    # Define predicate methods for querying state
    State.constants.each do |state|
      define_state_methods(State.const_get(state))
    end

    attr_reader :bootstrap
    attr_reader :attributes
    attr_accessor :exit_status
    attr_accessor :exit_description

    def initialize(bootstrap, attributes)
      super(bootstrap.config)
      @bootstrap = bootstrap

      attributes = attributes.to_hash if attributes.is_a? StartMessage
      @raw_attributes = attributes.dup
      @attributes = Instance.translate_attributes(@raw_attributes)
      @attributes['application_uris'] ||= []

      # Generate unique ID
      @attributes['instance_id'] ||= VCAP.secure_uuid

      # Contatenate 2 UUIDs to genreate a 32 chars long private_instance_id
      @attributes['private_instance_id'] ||= VCAP.secure_uuid + VCAP.secure_uuid

      self.state = State::BORN

      @exit_status = -1
      @exit_description = ''

      logger.user_data[:attributes] = AttributesLoggingFilter.new(@attributes)

      setup_container_from_snapshot
    end

    def setup
      setup_stat_collector
      setup_link
      setup_resume_stopping
      setup_crash_handler
    end

    def memory_limit_in_bytes
      limits['mem'].to_i * 1024 * 1024
    end

    def disk_limit_in_bytes
      limits['disk'].to_i * 1024 * 1024
    end

    def file_descriptor_limit
      limits['fds'].to_i
    end

    def instance_path_available?
      state == State::RUNNING || state == State::CRASHED
    end

    def consuming_memory?
      case state
        when State::BORN, State::STARTING, State::RUNNING, State::STOPPING
          true
        else
          false
      end
    end

    def consuming_disk?
      case state
        when State::BORN, State::STARTING, State::RUNNING, State::STOPPING,
          State::CRASHED
          true
        else
          false
      end
    end

    def instance_path
      attributes['instance_path'] ||=
        begin
          raise 'Instance path unavailable' unless instance_path_available?
          raise 'Warden container path not present' if container.path.nil?

          File.expand_path(container_relative_path(container.path))
        end
    end

    def validate
      self.class.schema.validate(attributes)
    end

    def state
      attributes['state']
    end

    def state=(state)
      transition = Transition.new(attributes['state'], state)

      attributes['state'] = state
      attributes['state_timestamp'] = Time.now.to_f

      state_time = "state_#{state.to_s.downcase}_timestamp"
      attributes[state_time] = Time.now.to_f

      emit(transition)
    end

    def state_timestamp
      attributes['state_timestamp']
    end

    def droplet
      bootstrap.droplet_registry[droplet_sha1]
    end

    def application_uris=(uris)
      attributes['application_uris'] = uris
      nil
    end

    def application_version=(version)
      attributes['application_version'] = version
      nil
    end

    def change_instance_id!
      attributes['instance_id'] = VCAP.secure_uuid
    end

    def to_s
      'Instance(id=%s, idx=%s, app_id=%s)' % [instance_id.slice(0, 4), instance_index, application_id]
    end

    def egress_network_rules
      attributes['egress_network_rules'] || []
    end

    def promise_state(from, to = nil)
      Promise.new do |p|
        if !Array(from).include?(state)
          p.fail(TransitionError.new(state, to))
        else
          if to
            self.state = to
          end

          p.deliver
        end
      end
    end

    def promise_setup_environment
      Promise.new do |p|
        script = 'cd / && mkdir -p home/vcap/app && chown vcap:vcap home/vcap/app && ln -s home/vcap/app /app'
        container.run_script(:app, script, true)

        p.deliver
      end
    end

    def promise_extract_droplet
      Promise.new do |p|
        script = "cd /home/vcap/ && tar zxf #{droplet.droplet_path}"

        container.run_script(:app, script)

        p.deliver
      end
    end

    def promise_start
      Promise.new do |p|
        env = Env.new(StartMessage.new(@raw_attributes), self)

        if staged_info
          command = start_command || staged_info['start_command']

          unless command
            p.fail(MissingStartCommand.new)
            next
          end

          start_script =
            Dea::StartupScriptGenerator.new(
              command,
              env.exported_user_environment_variables,
              env.exported_system_environment_variables
            ).generate
        else
          start_script = env.exported_environment_variables + "./startup;\nexit"
        end

        response = container.spawn(start_script,
                                   container.resource_limits(self.file_descriptor_limit, NPROC_LIMIT))

        attributes['warden_job_id'] = response.job_id

        container.update_path_and_ip
        bootstrap.snapshot.save

        p.deliver
      end
    end

    def promise_exec_hook_script(key)
      Promise.new do |p|
        if bootstrap.config['hooks'] && bootstrap.config['hooks'][key]
          script_path = bootstrap.config['hooks'][key]
          if File.exist?(script_path)
            script = []
            script << 'umask 077'
            script << Env.new(StartMessage.new(@raw_attributes), self).exported_environment_variables
            script << File.read(script_path)
            script << 'exit'
            container.run_script(:app, script.join("\n"))
          else
            logger.warn('droplet.hook-script.missing', hook: key, script_path: script_path)
          end
        end
        p.deliver
      end
    end

    def start(&callback)
      p = Promise.new do
        logger.info('droplet.starting')

        promise_state(State::BORN, State::STARTING).resolve

        # Concurrently download droplet and setup container
        Promise.run_in_parallel_and_join(
          promise_droplet,
          promise_container
        )

        Promise.run_serially(
          promise_extract_droplet,
          promise_exec_hook_script('before_start'),
          promise_start
        )

        on(Transition.new(:starting, :crashed)) do
          cancel_health_check
        end

        # Fire off link so that the health check can be cancelled when the
        # instance crashes before the health check completes.
        link

        if promise_health_check.resolve
          promise_state(State::STARTING, State::RUNNING).resolve
          logger.info('droplet.healthy')
          promise_exec_hook_script('after_start').resolve
        else
          logger.warn('droplet.unhealthy')
          p.fail(HealthCheckFailed.new)
        end

        p.deliver
      end

      resolve_and_log(p, 'instance.start') do |error, _|
        if error
          # An error occured while starting, mark as crashed
          self.exit_description = determine_exit_description_from_error(error)
          self.state = State::CRASHED
        end

        callback.call(error) unless callback.nil?
      end
    end

    def promise_container
      Promise.new do |p|
        bind_mounts = [{'src_path' => droplet.droplet_dirname, 'dst_path' => droplet.droplet_dirname}]
        with_network = true
        container.create_container(
          bind_mounts: bind_mounts + config['bind_mounts'],
          limit_cpu: cpu_shares,
          byte: disk_limit_in_bytes,
          inode: config.instance_disk_inode_limit,
          limit_memory: memory_limit_in_bytes,
          setup_inbound_network: with_network,
          egress_rules: egress_network_rules)

        attributes['warden_handle'] = container.handle

        promise_setup_environment.resolve
        p.deliver
      end
    end

    def instance_host_port
      container.network_ports['host_port']
    end

    def instance_container_port
      container.network_ports['container_port']
    end

    def promise_droplet
      Promise.new do |p|
        droplet.download(droplet_uri) do |error|
          if error
            logger.debug('droplet.download.failed',
                         duration: p.elapsed_time,
                         error: error,
                         backtrace: error.backtrace)

            p.fail(error)
          else
            logger.debug('droplet.download.succeeded',
                         duration: p.elapsed_time,
                         destination: droplet.droplet_path)

            p.deliver
          end
        end
      end
    end

    def stop(&callback)
      p = Promise.new do
        logger.info('droplet.stopping')

        promise_exec_hook_script('before_stop').resolve

        promise_state([State::STOPPING, State::RUNNING, State::EVACUATING], State::STOPPING).resolve

        promise_exec_hook_script('after_stop').resolve

        promise_stop.resolve

        promise_state(State::STOPPING, State::STOPPED).resolve

        p.deliver
      end

      resolve_and_log(p, 'instance.stop') do |error, _|
        callback.call(error) unless callback.nil?
      end
    end

    def promise_copy_out
      Promise.new do |p|
        new_instance_path = File.join(config.crashes_path, instance_id)
        new_instance_path = File.expand_path(new_instance_path)
        copy_out_request('/home/vcap/logs/', new_instance_path + '/logs')

        attributes['instance_path'] = new_instance_path

        p.deliver
      end
    end

    def setup_crash_handler
      # Resuming to crashed state
      on(Transition.new(:resuming, :crashed)) do
        crash_handler
      end

      # On crash
      on(Transition.new(:starting, :crashed)) do
        crash_handler
      end

      # On crash
      on(Transition.new(:running, :crashed)) do
        crash_handler
      end
    end

    def promise_crash_handler
      Promise.new do |p|
        if container.handle
          promise_copy_out.resolve
          promise_destroy.resolve

          container.close_all_connections
        end

        p.deliver
      end
    end

    def crash_handler(&callback)
      Promise.resolve(promise_crash_handler) do |error, _|
        if error
          logger.warn('droplet.crash-handler.error', error: error, backtrace: error.backtrace)
        end

        callback.call(error) unless callback.nil?
      end
    end

    def setup_stat_collector
      on(Transition.new(:resuming, :running)) do
        stat_collector.start
      end

      on(Transition.new(:starting, :running)) do
        stat_collector.start
      end

      on(Transition.new(:running, :stopping)) do
        stat_collector.stop
      end

      on(Transition.new(:running, :crashed)) do
        stat_collector.stop
      end
    end

    def setup_link
      # Resuming to running state
      on(Transition.new(:resuming, :running)) do
        link
      end
    end

    def setup_resume_stopping
      on(Transition.new(:resuming, :stopping)) do
        link do
          stop
        end
      end
    end

    def promise_link
      Promise.new do |p|
        p.deliver(container.link(attributes['warden_job_id']))
      end
    end

    def link(&callback)
      Promise.resolve(promise_link) do |error, link_response|
        if error
          logger.warn('droplet.warden.link.failed', error: error, backtrace: error.backtrace)

          self.exit_status = -1
          self.exit_description = 'unknown'
        else
          description = determine_exit_description_from_link_response(link_response)

          logger.warn('droplet.warden.link.completed', exit_status: link_response.exit_status, exit_description: description)

          self.exit_status = link_response.exit_status
          self.exit_description = description
        end

        case self.state
          when State::STARTING
            self.state = State::CRASHED
          when State::RUNNING
            logger.info('droplet.instance.crashed', uptime: (Time.now - attributes['state_running_timestamp']))

            self.state = State::CRASHED
          else
            # Linking likely completed because of stop
        end

        callback.call(error) unless callback.nil?
      end
    end

    def promise_read_instance_manifest(container_path)
      Promise.new do |p|
        if container_path.nil?
          p.deliver({})
          next
        end

        manifest_path = container_relative_path(container_path, 'droplet.yaml')
        if File.exist?(manifest_path)
          manifest = YAML.load_file(manifest_path)
          p.deliver(manifest)
        else
          p.deliver({})
        end
      end
    end

    def promise_port_open(port)
      Promise.new do |p|
        host = bootstrap.local_ip

        logger.debug('droplet.healthcheck.port', host: host, port: port)

        @health_check = Dea::HealthCheck::PortOpen.new(host, port) do |hc|
          hc.callback { p.deliver(true) }

          hc.errback do
            Dea::Loggregator.emit_error(application_id, "Instance (index #{instance_index}) failed to start accepting connections")
            p.deliver(false)
          end

          hc.timeout(health_check_timeout)
        end
      end
    end

    def promise_state_file_ready(path)
      Promise.new do |p|
        logger.debug('droplet.healthcheck.file', path: path)

        @health_check = Dea::HealthCheck::StateFileReady.new(path) do |hc|
          hc.callback { p.deliver(true) }

          hc.errback { p.deliver(false) }

          hc.timeout(60 * 5)
        end
      end
    end

    def cancel_health_check
      if @health_check
        @health_check.fail
        @health_check = nil
      end
    end

    def promise_health_check
      Promise.new do |p|
        begin
          logger.debug('droplet.health-check.get-container-info')
          container.update_path_and_ip
          logger.debug('droplet.health-check.container-info-ok')
        rescue => e
          logger.error('droplet.health-check.container-info-failed', error: e, backtrace: e.backtrace)

          p.deliver(false)
        else
          manifest = promise_read_instance_manifest(container.path).resolve

          if manifest && manifest['state_file']
            manifest_path = container_relative_path(container.path, manifest['state_file'])
            p.deliver(promise_state_file_ready(manifest_path).resolve)
          elsif !application_uris.empty?
            p.deliver(promise_port_open(instance_container_port).resolve)
          else
            p.deliver(true)
          end
        end
      end
    end

    def attributes_and_stats
      @attributes.merge({
          'used_memory_in_bytes' => used_memory_in_bytes,
          'used_disk_in_bytes' => used_disk_in_bytes,
          'computed_pcpu' => computed_pcpu
      })
    end

    def used_memory_in_bytes
      stat_collector.used_memory_in_bytes
    end

    def used_disk_in_bytes
      stat_collector.used_disk_in_bytes
    end

    def computed_pcpu
      stat_collector.computed_pcpu
    end

    def cpu_shares
      calculated_shares = limits['mem'].to_i / config['instance']['memory_to_cpu_share_ratio']
      if calculated_shares > config['instance']['max_cpu_share_limit']
        return config['instance']['max_cpu_share_limit']
      elsif calculated_shares < config['instance']['min_cpu_share_limit']
        return config['instance']['min_cpu_share_limit']
      end
      calculated_shares
    end

    def stat_collector
      @stat_collector ||= StatCollector.new(container)
    end

    def staged_info
      @staged_info ||= begin
        Dir.mktmpdir do |destination_dir|
          staging_file_name = 'staging_info.yml'
          copied_file_name = "#{destination_dir}/#{staging_file_name}"

          copy_out_request("/home/vcap/#{staging_file_name}", destination_dir)

          YAML.load_file(copied_file_name) if File.exists?(copied_file_name)
        end
      end
    end

    def snapshot_attributes
      {
        'cc_partition' => attributes['cc_partition'],

        'instance_id' => attributes['instance_id'],
        'instance_index' => attributes['instance_index'],
        'private_instance_id' => attributes['private_instance_id'],

        'warden_handle' => attributes['warden_handle'],
        'limits' => attributes['limits'],
        'health_check_timeout' => attributes['health_check_timeout'],

        'environment' => attributes['environment'],
        'services' => attributes['services'],

        'application_id' => attributes['application_id'],
        'application_version' => attributes['application_version'],
        'application_name' => attributes['application_name'],
        'application_uris' => attributes['application_uris'],

        'droplet_sha1' => attributes['droplet_sha1'],
        'droplet_uri' => attributes['droplet_uri'],

        'start_command' => attributes['start_command'],

        'state' => attributes['state'],

        'warden_job_id' => attributes['warden_job_id'],
        'warden_container_path' => container.path,
        'warden_host_ip' => container.host_ip,
        'instance_host_port' => container.network_ports['host_port'],
        'instance_container_port' => container.network_ports['container_port'],

        'syslog_drain_urls' => attributes['services'].map { |svc_hash| svc_hash['syslog_drain_url'] }.compact,

        'state_starting_timestamp' => attributes['state_starting_timestamp']
      }
    end

    private

    def setup_container_from_snapshot
      container.handle = @attributes['warden_handle']
      container.network_ports['host_port'] = @attributes['instance_host_port']
      container.network_ports['container_port'] = @attributes['instance_container_port']
    end

    def determine_exit_description_from_link_response(link_response)
      info = link_response.info
      return 'cannot be determined' unless info

      return info.events.first if info.events && info.events.first

      'app instance exited'
    end

    def determine_exit_description_from_error(error)
      case error
        when UserFacingError
          error.to_s
        else
          'failed to start'
      end
    end

    def container_relative_path(root, *parts)
      # This can be removed once warden's wsh branch is merged to master
      if File.directory?(File.join(root, 'rootfs'))
        return File.join(root, 'rootfs', 'home', 'vcap', *parts)
      end

      # New path
      File.join(root, 'tmp', 'rootfs', 'home', 'vcap', *parts)
    end

    def health_check_timeout
      app_specific_health_check_timeout || default_health_check_timeout
    end

    def app_specific_health_check_timeout
      attributes['health_check_timeout']
    end

    def default_health_check_timeout
      config['default_health_check_timeout']
    end

    def logger
      tags = {
        'instance_id' => instance_id,
        'instance_index' => instance_index,
        'application_id' => application_id,
        'application_version' => application_version,
        'application_name' => application_name,
      }

      @logger ||= self.class.logger.tag(tags)
    end
  end
end
