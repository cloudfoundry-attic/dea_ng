# coding: UTF-8

require 'spec_helper'
require 'em-http'
require 'dea/config'

require 'dea/directory_server/directory_server_v2'
require 'dea/staging/staging_task'

describe Dea::StagingTask do
  let(:loggregator_emitter) { FakeEmitter.new }

  let(:memory_limit_mb) { 256 }
  let(:disk_limit_mb) { 1025 }
  let(:disk_inode_limit) { 12345 }

  let!(:workspace_dir) do
    staging_task.workspace.workspace_dir # force workspace creation
  end

  let(:max_staging_duration) { 900 }
  let(:rootfs) { '/var/path/to/rootfs' }

  let(:config) do
    {
      'base_dir' => base_dir,
      'directory_server' => {
        'file_api_port' => 1234
      },
      'stacks' => [
        {
          'name' => attributes['stack'],
          'package_path' => rootfs,
        },
        {
          'name' => 'not-my-stack',
          'package_path' => 'where_is_this',
        }
      ],
      'staging' => {
        'cpu_limit_shares' => 512,
        'memory_limit_mb' => memory_limit_mb,
        'disk_limit_mb' => disk_limit_mb,
        'disk_inode_limit' => disk_inode_limit,
        'max_staging_duration' => max_staging_duration
      },
    }
  end

  let(:base_dir) { Dir.mktmpdir('base_dir') }
  let(:bootstrap) { double(:bootstrap, config: Dea::Config.new(config), snapshot: double(:snapshot)) }
  let(:dir_server) { Dea::DirectoryServerV2.new('domain', 1234, nil, config) }

  let(:logger) do
    double('logger').tap do |l|
      %w(debug debug2 info warn log_exception error).each { |m| l.stub(m) }
    end
  end

  let(:attributes) { valid_staging_attributes }

  let(:buildpacks_in_use) do
    [ {key: 'buildpack1', uri: URI('http://www.goolge.com')},
      {key: 'buildpack2', uri: URI('http://www.goolge2.com')}
    ]
  end

  let(:successful_promise) { Dea::Promise.new { |p| p.deliver } }

  let(:failing_promise) { Dea::Promise.new { |p| raise 'failing promise' } }

  let (:empty_streams) { double(:stdout => '', :stderr => '') }

  let(:staging_message) { StagingMessage.new(attributes) }

  subject(:staging_task) { Dea::StagingTask.new(bootstrap, dir_server, staging_message, buildpacks_in_use) }

  after { FileUtils.rm_rf(workspace_dir) if File.exists?(workspace_dir) }

  before do
    staging_task.stub(:workspace_dir) { workspace_dir }
    staging_task.stub(:staged_droplet_path) { __FILE__ }
    staging_task.stub(:downloaded_app_package_path) { '/path/to/downloaded/droplet' }
    staging_task.stub(:logger) { logger }
    staging_task.stub(:container_exists?) { true }

    Dea::Loggregator.staging_emitter = loggregator_emitter
  end

  describe '#promise_stage' do
    let(:spawn_response) { double(job_id: 25) }

    before do
      allow(staging_task.container).to receive(:spawn) { spawn_response }
      allow(staging_task.container).to receive(:link_or_raise)
      allow(staging_task.bootstrap.snapshot).to receive(:save)
    end

    describe 'assembles staging command correctly' do
      it 'calls the container#spawn with the staging command' do
        expect(staging_task.container).to receive(:spawn) do |cmd|
          expect(cmd).to include 'export FOO="BAR";'
          expect(cmd).to include 'export STAGING_TIMEOUT="900.0";'
          expect(cmd).to include 'export MEMORY_LIMIT="512m";' # the user assiged 512 should overwrite the system 256
          expect(cmd).to include 'export VCAP_SERVICES=\{\}'

          expect(cmd).to match %r{.*/bin/run .*/plugin_config | tee -a}

          spawn_response
        end

        with_event_machine do
          staging_task.promise_stage.resolve
          done
        end
      end

      context 'when env variables need to be escaped' do
        before { attributes['properties']['environment'] = ['PATH=x y z', "FOO=z'y\"d", 'BAR=', 'BAZ=foo=baz'] }

        it 'copes with spaces' do
          staging_task.container.should_receive(:spawn) do |cmd|
            expect(cmd).to include('export PATH="x y z";')

            spawn_response
          end

          with_event_machine do
            staging_task.promise_stage.resolve
            done
          end
        end

        it 'copes with quotes' do
          staging_task.container.should_receive(:spawn) do |cmd|
            expect(cmd).to include(%Q{export FOO="z'y\\"d";})
          end.and_return(spawn_response)

          with_event_machine do
            staging_task.promise_stage.resolve
            done
          end
        end

        it 'copes with blank' do
          staging_task.container.should_receive(:spawn) do |cmd|
            expect(cmd).to include('export BAR="";')

            spawn_response
          end

          with_event_machine do
            staging_task.promise_stage.resolve
            done
          end
        end

        it 'copes with equal sign' do
          staging_task.container.should_receive(:spawn) do |cmd|
            expect(cmd).to include('export BAZ="foo=baz";')
          end.and_return(spawn_response)

          with_event_machine do
            staging_task.promise_stage.resolve
            done
          end
        end
      end
    end

    it 'saves warden job id to the snapshot' do
      expect(staging_task.snapshot_attributes['warden_job_id']).to be_nil

      expect(staging_task.bootstrap.snapshot).to receive(:save)

      with_event_machine do
        staging_task.promise_stage.resolve
        done
      end

      expect(staging_task.snapshot_attributes['warden_job_id']).to eq(25)
    end

    it 'links to the job' do
      expect(staging_task.container).to receive(:link_or_raise).with(25)

      with_event_machine do
        staging_task.promise_stage.resolve
        done
      end
    end

    context 'when job fails' do
      let (:staging_result) { double(:stdout => 'stdout message', :stderr => 'stderr message') }
      let (:staging_error) { Container::WardenError.new('Failed to stage', staging_result) }

      before { staging_task.container.should_receive(:link_or_raise).and_raise(staging_error) }

      it 'raises Container::WardenError' do

        with_event_machine do
          expect { staging_task.promise_stage.resolve }.to raise_error(Container::WardenError)
          done
        end
      end
    end

    context 'when job exceeds staging timeout' do
      let(:max_staging_duration) { 0.1 }
      let(:container_staging_duration) { 0.2 }

      it 'fails with a TimeoutError' do
        stop_request = ::Warden::Protocol::StopRequest.new(handle: staging_task.container.handle, kill: true)
        allow(staging_task.container).to receive(:call).with(:stop, stop_request)

        allow(staging_task.container).to receive(:link_or_raise) do
          f = Fiber.current

          EM.add_timer(container_staging_duration) do
            f.resume
          end

          Fiber.yield
        end

        with_event_machine do
          Fiber.new do
            expect { staging_task.promise_stage.resolve }.to raise_error('Staging in container timed out')
            done
          end.resume
        end
      end
    end
  end

  describe '#task_log' do
    describe 'when staging has not yet started' do
      subject { staging_task.task_log }
      it { should be_nil }
    end

    describe 'once staging has started' do
      before do
        File.open(File.join(workspace_dir, 'staging_task.log'), 'w') do |f|
          f.write 'some log content'
        end
      end

      it 'reads the staging_task log file' do
        staging_task.task_log.should == 'some log content'
      end
    end
  end

  describe '#task_info' do
    context 'when staging info file exists' do
      before do
        contents = <<YAML
---
detected_buildpack: Ruby/Rack
YAML
        staging_info = File.join(workspace_dir, 'staging_info.yml')
        File.open(staging_info, 'w') { |f| f.write(contents) }
      end

      it 'parses staging info file' do
        staging_task.task_info['detected_buildpack'].should eq('Ruby/Rack')
      end
    end

    context 'when staging info file does not exist' do
      it 'returns empty hash if' do
        staging_task.task_info.should be_empty
      end
    end
  end

  describe 'procfile' do
    before do
      contents = <<YAML
---
effective_procfile:
  web: npm start
YAML
      staging_info = File.join(workspace_dir, 'staging_info.yml')
      File.open(staging_info, 'w') { |f| f.write(contents) }
    end

    it 'returns the detected buildpack' do
      staging_task.procfile.should eq({"web" => "npm start"})
    end
  end

  describe '#detected_buildpack' do
    before do
      contents = <<YAML
---
detected_buildpack: Ruby/Rack
YAML
      staging_info = File.join(workspace_dir, 'staging_info.yml')
      File.open(staging_info, 'w') { |f| f.write(contents) }
    end

    it 'returns the detected buildpack' do
      staging_task.detected_buildpack.should eq('Ruby/Rack')
    end
  end

  describe '#detected_start_command' do
    before do
      contents = <<YAML
---
start_command: bacofoil
YAML
      staging_info = File.join(workspace_dir, 'staging_info.yml')
      File.open(staging_info, 'w') { |f| f.write(contents) }
    end

    it 'returns the detected start command' do
      staging_task.detected_start_command.should eq('bacofoil')
    end
  end

  describe '#buildpack_path' do
    before do
      contents = <<YAML
---
buildpack_path: some/buildpack/path
YAML
      staging_info = File.join(workspace_dir, 'staging_info.yml')
      File.open(staging_info, 'w') { |f| f.write(contents) }
    end

    it 'returns the buildpack path' do
      staging_task.buildpack_path.should eq('some/buildpack/path')
    end
  end

  describe '#buildpack_key' do
    let(:buildpack_path) { "#{staging_task.workspace.admin_buildpacks_dir}/admin_key" }

    before do
      FileUtils.mkdir_p(staging_task.workspace.admin_buildpacks_dir)
      FileUtils.mkdir_p(buildpack_path)
      contents = <<YAML
---
buildpack_path: #{buildpack_path}
YAML
      staging_info = File.join(workspace_dir, 'staging_info.yml')
      File.open(staging_info, 'w') { |f| f.write(contents) }
    end

    context 'when an admin buildpack is detected' do
      it 'returns the correct buildpack key' do
        staging_task.buildpack_key.should eq('admin_key')
      end
    end

    context 'when an admin buildpack is specified' do
      let(:buildpack_path) { "#{staging_task.workspace.admin_buildpacks_dir}/ignored" }
      let(:attributes) do
        staging_attributes = valid_staging_attributes
        staging_attributes['properties']['buildpack_key'] = 'specified_admin_key'
        staging_attributes
      end

      it 'returns the specified admin key' do
        staging_task.buildpack_key.should eq('specified_admin_key')
      end
    end

    context 'when a detected system buildpack is used' do
      let(:buildpack_path) { "#{staging_task.workspace.system_buildpacks_dir}/java" }

      it 'returns a nil buildpack key' do
        staging_task.buildpack_key.should be_nil
      end
    end
  end

  describe '#error_info' do
    let(:error_type) { "NoAppDetectedError" }
    let(:error_message) { "An application could not be detected..." }

    context 'when a staging error is present' do
      before do
        contents = <<YAML
---
staging_error:
  type: #{error_type}
  message: #{error_message}
YAML
        staging_info = File.join(workspace_dir, 'staging_info.yml')
        File.open(staging_info, 'w') { |f| f.write(contents) }
      end

      it 'returns a hash with the error type and message' do
        staging_task.error_info['type'].should eq(error_type)
        staging_task.error_info['message'].should eq(error_message)
      end
    end

    context 'when a staging error is not present' do
      it 'returns returns nil' do
        staging_task.error_info.should be_nil
      end
    end
  end

  describe '#streaming_log_url' do
    let(:url) { staging_task.streaming_log_url }

    it 'returns url for staging log' do
      url.should include("/staging_tasks/#{staging_task.task_id}/file_path",)
    end

    it 'includes path to staging task output' do
      url.should include 'path=%2Ftmp%2Fstaged%2Flogs%2Fstaging_task.log'
    end

    it 'hmacs url' do
      url.should match(/hmac=.*/)
    end
  end

  describe '#path_in_container' do
    context 'when given path is not nil' do
      context 'when container path is set' do
        before do
          staging_task.container.stub(:path).and_return('/container/path')
        end

        it 'returns path inside warden container root file system' do
          staging_task.path_in_container('path/to/file').should == '/container/path/tmp/rootfs/path/to/file'
        end
      end

      context 'when container path is not set' do
        before { staging_task.container.stub(:path => nil) }

        it 'returns nil' do
          staging_task.path_in_container('path/to/file').should be_nil
        end
      end
    end

    context 'when given path is nil' do
      context 'when container path is set' do
        before do
          staging_task.container.stub(:path).and_return('/container/path')
        end

        it 'returns path inside warden container root file system' do
          staging_task.path_in_container(nil).should == '/container/path/tmp/rootfs/'
        end
      end

      context 'when container path is not set' do
        before { staging_task.stub(:container_path => nil) }

        it 'returns nil' do
          staging_task.path_in_container('path/to/file').should be_nil
        end
      end
    end
  end

  describe '#start' do
    def stub_staging_setup
      %w(
         app_download
         buildpack_cache_download
         prepare_staging_log
         app_dir
      ).each do |step|
        staging_task.stub("promise_#{step}").and_return(successful_promise)
      end
      staging_task.container.stub(:create_container)
      staging_task.container.stub(:update_path_and_ip)
    end

    def stub_staging
      %w(unpack_app
         unpack_buildpack_cache
         stage
         pack_app
         copy_out
         save_droplet
         log_upload_started
         app_upload
         pack_buildpack_cache
         copy_out_buildpack_cache
         buildpack_cache_upload
         staging_info
         task_log
         destroy
      ).each do |step|
        staging_task.stub("promise_#{step}").and_return(successful_promise)
      end
    end

    def stub_staging_upload
      %w(
      app_upload
      save_buildpack_cache
      destroy
      ).each do |step|
        staging_task.stub("promise_#{step}").and_return(successful_promise)
      end
    end

    def self.it_calls_callback(callback_name, options={})
      describe "after_#{callback_name}_callback" do
        before do
          stub_staging_setup
          stub_staging
          stub_staging_upload
        end

        context 'when there is no callback registered' do
          it "doesn't not try to call registered callback" do
            staging_task.start
          end
        end

        context 'when there is callback registered' do
          before do
            @received_count = 0
            @received_error = nil
            staging_task.send("after_#{callback_name}_callback") do |error|
              @received_count += 1
              @received_error = error
            end
          end

          context "and staging task succeeds finishing #{callback_name}" do
            it 'calls registered callback without an error' do
              staging_task.start
              @received_count.should == 1
              @received_error.should be_nil
            end
          end

          context "and staging task fails before finishing #{callback_name}" do
            before { staging_task.stub(options[:failure_cause]).and_return(failing_promise) }

            it 'calls registered callback with an error' do
              staging_task.start rescue nil
              @received_count.should == 1
              @received_error.to_s.should == 'failing promise'
            end
          end

          context 'and the callback itself fails' do
            before do
              staging_task.send("after_#{callback_name}_callback") do |_|
                @received_count += 1
                raise 'failing callback'
              end
            end

            it 'cleans up workspace' do
              expect {
                staging_task.start
              }.to change { File.exists?(workspace_dir) }.from(true).to(false)
            end if options[:callback_failure_cleanup_assertions]

            it 'calls registered callback exactly once' do
              staging_task.start
              @received_count.should == 1
            end

            context 'and there is no error from staging' do
              it 'does not raises an error from the callback' do
                staging_task.start
              end
            end

            context 'and there is an error from staging' do
              before { staging_task.stub(options[:failure_cause]).and_return(failing_promise) }

              it 'does not raise the staging error' do
                staging_task.start
              end
            end
          end
        end
      end
    end

    it_calls_callback :setup, :failure_cause => :promise_app_download

    it_calls_callback :complete, {
      :failure_cause => :promise_stage,
      :callback_failure_cleanup_assertions => true
    }

    context 'when finished' do
      before do
        stub_staging_setup
        staging_task.should_receive(:resolve_staging)
        stub_staging_upload
      end

      it 'should close all connections' do
        expect(staging_task.container).to receive(:close_all_connections)
        staging_task.start
      end
    end

    it 'should clean up after itself' do
      staging_task.workspace.stub(:prepare).and_raise('Error')
      stub_staging_upload

      staging_task.start
      File.exists?(workspace_dir).should be_false
    end

    context 'when a script fails' do
      before do
        stub_staging_setup
        stub_staging
        staging_task.stub(:promise_stage).and_raise('Script Failed')
      end

      it 'still copies out the task log' do
        staging_task.should_receive(:promise_task_log) { double('promise', :resolve => nil) }
        staging_task.start rescue nil
      end

      it 'returns an error in response' do
        response = nil
        staging_task.after_complete_callback do |callback_response|
          response = callback_response
        end

        staging_task.start

        expect(response.message).to match /Script Failed/
      end

      it 'does not uploads droplet' do
        staging_task.should_not_receive(:resolve_staging_upload)
        staging_task.start rescue nil
      end
    end

    describe '#bind_mounts' do
      it 'includes the workspace dir' do
        staging_task.bind_mounts.should include('src_path' => staging_task.workspace.workspace_dir,
                                              'dst_path' => staging_task.workspace.workspace_dir)
      end

      it 'includes the build pack url' do
        staging_task.bind_mounts.should include('src_path' => staging_task.workspace.buildpack_dir,
                                           'dst_path' => staging_task.workspace.buildpack_dir)
      end

      it 'includes the configured bind mounts' do
        mount = {
          'src_path' => 'a',
          'dst_path' => 'b'
        }
        staging_task.config['bind_mounts'] = [mount]
        staging_task.bind_mounts.should include(mount)
      end
    end

    it 'performs staging setup operations in correct order' do
      with_network = false
      staging_task.workspace.should_receive(:prepare).ordered
      staging_task.workspace.workspace_dir
      staging_task.container.should_receive(:create_container).
        with(bind_mounts: staging_task.bind_mounts,
             limit_cpu: staging_task.staging_config['cpu_limit_shares'],
             byte: staging_task.disk_limit_in_bytes,
             inode: staging_task.disk_inode_limit,
             limit_memory: staging_task.memory_limit_in_bytes,
             setup_inbound_network: with_network,
             egress_rules: staging_task.staging_message.egress_rules,
             rootfs: rootfs).ordered
      %w(
        promise_app_download
        promise_prepare_staging_log
        promise_app_dir
      ).each do |step|
        staging_task.should_receive(step).ordered.and_return(successful_promise)
      end
      staging_task.container.should_receive(:update_path_and_ip).ordered

      stub_staging
      stub_staging_upload
      staging_task.start
    end

    context 'when buildpack_cache_download_uri is provided' do
      subject(:staging_task) do
        Dea::StagingTask.new(
          bootstrap,
          dir_server,
          StagingMessage.new(attributes.merge('buildpack_cache_download_uri' => 'http://www.someurl.com')),
          buildpacks_in_use
        )
      end

      it 'downloads buildpack cache' do
        staging_task.should_receive(:promise_buildpack_cache_download)

        stub_staging
        stub_staging_setup

        staging_task.start
      end
    end

    it 'performs staging operations in correct order' do
      %w(unpack_app
         unpack_buildpack_cache
         stage
         pack_app
         copy_out
         save_droplet
         log_upload_started
         staging_info
         task_log
         ).each do |step|
        staging_task.should_receive("promise_#{step}").ordered.and_return(successful_promise)
      end

      stub_staging_setup
      stub_staging_upload
      staging_task.start
    end

    it 'performs staging upload operations in correct order' do
      %w(
      app_upload
      save_buildpack_cache
      destroy
      ).each do |step|
        staging_task.should_receive("promise_#{step}").ordered.and_return(successful_promise)
      end

      stub_staging_setup
      stub_staging
      staging_task.start
    end

    it 'triggers callbacks in correct order' do
      stub_staging_setup
      stub_staging
      stub_staging_upload

      staging_task.should_receive(:resolve_staging).ordered
      staging_task.should_receive(:resolve_staging_upload).ordered.and_call_original
      staging_task.should_receive(:promise_app_upload).ordered
      staging_task.should_receive(:promise_save_buildpack_cache).ordered
      staging_task.should_receive(:trigger_after_complete).ordered

      staging_task.start
    end

    context 'when the rootfs does not exist' do
      before do
        config['stacks'][0]['name'] = 'wrong-name'
      end

      it 'reports an error' do
        response = nil
        staging_task.after_complete_callback do |callback_response|
          response = callback_response
        end

        stub_staging
        stub_staging_upload
        staging_task.start
        expect(response.message).to match(/Stack my-stack does not exist/)
      end
    end

    context 'when the upload fails' do
      let(:some_terrible_error) { RuntimeError.new('error') }
      before do
        stub_staging_setup
        stub_staging
        stub_staging_upload
      end

      def it_raises_an_error
        response = nil
        staging_task.after_complete_callback do |callback_response|
          response = callback_response
        end

        staging_task.start
        expect(response).to eq(some_terrible_error)
      end

      it 'copes with uploading errors' do
        staging_task.stub(:promise_app_upload).and_raise(some_terrible_error)

        it_raises_an_error
      end

      it 'copes with buildpack cache errors' do
        staging_task.stub(:promise_save_buildpack_cache).and_raise(some_terrible_error)

        it_raises_an_error
      end
    end
  end

  describe '#stop' do
    context 'if container exists' do
      before { staging_task.container.stub(:handle) { 'maria' } }
      it 'sends stop request to warden container' do
        staging_task.should_receive(:promise_stop).and_return(successful_promise)
        staging_task.stop
      end
    end

    context 'if container does not exist' do
      before { staging_task.container.stub(:handle) { nil } }
      it 'does NOT send stop request to warden container' do
        staging_task.should_not_receive(:promise_stop)
        staging_task.stop
      end
    end

    it 'calls the callback' do
      callback = lambda {}
      callback.should_receive(:call)
      staging_task.stop(&callback)
    end

    it 'triggers after stop callback' do
      staging_task.should_receive(:trigger_after_stop)
      staging_task.stop
    end

    it 'unregisters after complete callback' do
      staging_task.stub(:resolve_staging_setup)
      staging_task.stub(:resolve_staging_upload)
      staging_task.stub(:promise_destroy).and_return(successful_promise)
      # Emulate staging stop while running staging_task
      staging_task.stub(:resolve_staging) { staging_task.stop }

      staging_task.should_not_receive(:after_complete_callback)
      staging_task.start
    end
  end

  describe '#memory_limit_in_bytes' do
    context 'when unspecified' do
      before do
        config['staging'].delete('memory_limit_mb')
      end

      it 'uses 1GB as a default' do
        staging_task.memory_limit_in_bytes.should eq(1024*1024*1024)
      end
    end

    context 'when the app requests less than the config' do
      before do
        config['staging']['memory_limit_mb'] = 1024
        attributes['start_message']['limits']['mem'] = 512
      end

      it 'sets the memory_limit_in_bytes to the config value' do
        expect(staging_task.memory_limit_in_bytes).to eq(1024*1024*1024)
      end
    end

    context 'when the app requests more than the config' do
      before do
        config['staging']['memory_limit_mb'] = 1024
        attributes['start_message']['limits']['mem'] = 2048
      end

      it 'sets the memory_limit_in_bytes to the app value' do
        expect(staging_task.memory_limit_in_bytes).to eq(2048*1024*1024)
      end
    end
  end

  describe '#disk_limit_in_bytes' do
    it 'exports disk in bytes as specified in the config file' do
      staging_task.disk_limit_in_bytes.should eq(1024 * 1024 * disk_limit_mb)
    end

    context 'when unspecified' do
      before do
        config['staging'].delete('disk_limit_mb')
      end

      it 'uses 2GB as a default' do
        staging_task.disk_limit_in_bytes.should eq(2*1024*1024*1024)
      end
    end
  end

  describe '#disk_limit_mb and #mem_limit_mb' do
    context 'when specified in the staging message' do
      let(:mem_limit) { 1024 }
      let(:disk_limit) { 2048 }

      let(:attributes) do
        valid_staging_attributes.merge({
          "memory_limit" => mem_limit,
          "disk_limit" => disk_limit
        })
      end

      it 'returns the staging messages limit values' do
        expect(staging_task.disk_limit_mb).to eq(disk_limit)
        expect(staging_task.memory_limit_mb).to eq(mem_limit)
      end
    end

    context 'when unspecified' do
      let(:disk_limit_mb) { 3333 } # default staging disk limit of config object
      let(:memory_limit_mb) { 1234 }

      it 'returns the defaults' do
        expect(staging_task.disk_limit_mb).to eq(disk_limit_mb)
        expect(staging_task.memory_limit_mb).to eq(memory_limit_mb)
      end
    end
  end

  describe '#disk_inode_limit' do
    it 'exports disk with set inode as specified in the config file' do
      staging_task.disk_inode_limit.should eq(disk_inode_limit)
    end
  end

  describe '#promise_prepare_staging_log' do
    it 'assembles a shell command that creates staging_task.log file for tailing it' do
      staging_task.container.should_receive(:run_script) do |connection_name, cmd|
        cmd.should match 'mkdir -p /tmp/staged/logs && touch /tmp/staged/logs/staging_task.log'
      end
      staging_task.promise_prepare_staging_log.resolve
    end
  end

  describe '#promise_app_download' do
    subject do
      promise = staging_task.promise_app_download
      promise.resolve
      promise
    end

    let(:staging_app_file_path) { "#{workspace_dir}/app.zip" }

    context 'when there is an error' do
      before do
        Download.any_instance.stub(:download!).and_yield(
          RuntimeError.new('This is an error'))
      end

      it { expect { subject }.to raise_error(RuntimeError, 'This is an error') }

      it 'should not create an app file' do
        subject rescue nil
        expect(File.exists?(staging_task.workspace.downloaded_app_package_path)).to be_false
      end
    end

    context 'when there is no error' do
      before do
        Download.any_instance.stub(:download!).and_yield(nil)
      end

      its(:result) { should == [:deliver, nil] }

      it 'should rename the file' do
        subject
        expect(File.exists?(staging_app_file_path)).to be_true
        expect(sprintf('%o', File.stat(staging_app_file_path).mode)).to eq '100744'
      end
    end
  end

  describe '#promise_buildpack_cache_download' do
    subject do
      staging_task.workspace.prepare(staging_task.buildpack_manager)
      promise = staging_task.promise_buildpack_cache_download
      promise.resolve
      promise
    end

    let(:buildpack_cache_dest) { File.join workspace_dir, 'buildpack_cache.tgz' }

    context 'when there is an error' do
      before do
        Download.any_instance.stub(:download!).and_yield(
          RuntimeError.new('This is an error'))
      end

      its(:result) { should eq([:deliver, nil]) }

      it 'does not create the buildpack cache tarball' do
        subject
        expect(File.exists?(buildpack_cache_dest)).to be_false
      end
    end

    context 'when there is no error' do
      before { Download.any_instance.stub(:download!).and_yield(nil) }

      its(:result) { should eq([:deliver, nil]) }

      it 'should rename the file' do
        subject
        expect(File.exists?(buildpack_cache_dest)).to be_true
        expect(sprintf('%o', File.stat(buildpack_cache_dest).mode)).to eq '100744'
      end
    end
  end

  describe '#promise_unpack_app' do
    it 'assembles a shell command' do
      staging_task.container.should_receive(:run_script) do |connection_name, cmd|
        cmd.should include("unzip -q #{workspace_dir}/app.zip -d /tmp/unstaged")

        empty_streams
      end
      staging_task.promise_unpack_app.resolve
    end

    it 'logs to loggregator' do
      staging_task.container.should_receive(:run_script).and_return(double(:stdout => 'stdout message', :stderr => 'stderr message'))
      staging_task.promise_unpack_app.resolve
      app_id = staging_task.staging_message.app_id
      expect(loggregator_emitter.messages.size).to eql(1)
      expect(loggregator_emitter.error_messages.size).to eql(1)
      expect(loggregator_emitter.messages[app_id][0]).to eql('stdout message')
      expect(loggregator_emitter.error_messages[app_id][0]).to eql('stderr message')
    end
  end

  describe '#promise_unpack_buildpack_cache' do
    context 'when buildpack cache does not exist' do
      it 'does not run a warden command' do
        staging_task.container.should_not_receive(:run_script)
        staging_task.promise_unpack_buildpack_cache.resolve
      end
    end

    context 'when buildpack cache exists' do
      before do
        FileUtils.touch("#{workspace_dir}/buildpack_cache.tgz")
      end

      it 'assembles a shell command' do
        staging_task.container.should_receive(:run_script) do |_, cmd|
          cmd.should include("tar xfz #{workspace_dir}/buildpack_cache.tgz -C /tmp/cache")

          empty_streams
        end
        staging_task.promise_unpack_buildpack_cache.resolve
      end

      it 'logs to loggregator' do
        staging_task.container.should_receive(:run_script).and_return(double(:stdout => 'stdout message', :stderr => 'stderr message'))
        staging_task.promise_unpack_buildpack_cache.resolve
        app_id = staging_task.staging_message.app_id
        expect(loggregator_emitter.messages.size).to eql(1)
        expect(loggregator_emitter.error_messages.size).to eql(1)
        expect(loggregator_emitter.messages[app_id][0]).to eql('stdout message')
        expect(loggregator_emitter.error_messages[app_id][0]).to eql('stderr message')
      end
    end
  end

  describe '#promise_pack_app' do
    it 'assembles a shell command' do
      staging_task.container.should_receive(:run_script) do |connection_name, cmd|
        normalize_whitespace(cmd).should include('cd /tmp/staged && COPYFILE_DISABLE=true tar -czf /tmp/droplet.tgz .')
      end

      staging_task.promise_pack_app.resolve
    end
  end

  describe '#promise_pack_buildpack_cache' do
    it 'assembles a shell command' do
      staging_task.container.should_receive(:run_script) do |_, cmd|
        normalize_whitespace(cmd).should include('cd /tmp/cache && COPYFILE_DISABLE=true tar -czf /tmp/buildpack_cache.tgz .')
      end

      staging_task.promise_pack_buildpack_cache.resolve
    end
  end

  describe '#promise_save_buildpack_cache' do

    context 'when packing succeeds' do

      before do
        staging_task.stub(:promise_pack_buildpack_cache).and_return(successful_promise)
        staging_task.stub(:promise_copy_out_buildpack_cache).and_return(successful_promise)
        staging_task.stub(:promise_buildpack_cache_upload).and_return(successful_promise)
      end

      it 'copies out the buildpack cache' do
        staging_task.should_receive(:promise_copy_out_buildpack_cache).and_return(successful_promise)
        staging_task.promise_save_buildpack_cache.resolve
      end

      it 'uploads the buildpack cache' do
        staging_task.should_receive(:promise_buildpack_cache_upload).and_return(successful_promise)
        staging_task.promise_save_buildpack_cache.resolve
      end
    end

    context 'when packing fails' do

      before { staging_task.stub(:promise_pack_buildpack_cache).and_return(failing_promise) }

      it 'does not copy out the buildpack cache' do
        staging_task.should_not_receive :promise_copy_out_buildpack_cache
        staging_task.promise_save_buildpack_cache.resolve rescue nil
      end

      it 'does not upload the buildpack cache' do
        staging_task.should_not_receive :promise_buildpack_cache_upload
        staging_task.promise_save_buildpack_cache.resolve rescue nil
      end

    end
  end

  describe '#promise_app_upload' do
    subject do
      promise = staging_task.promise_app_upload
      promise.resolve
      promise
    end

    context 'when there is an error' do
      before do
        Upload.any_instance.stub(:upload!).and_yield(
          RuntimeError.new('This is an error'))
      end

      it { expect { subject }.to raise_error(RuntimeError, 'This is an error') }
    end

    context 'when there is no error' do
      before { Upload.any_instance.stub(:upload!).and_yield(nil) }
      its(:result) { should == [:deliver, nil] }
    end
  end

  describe '#promise_buildpack_cache_upload' do
    subject do
      promise = staging_task.promise_buildpack_cache_upload
      promise.resolve
      promise
    end

    context 'when there is an error' do
      before do
        Upload.any_instance.stub(:upload!).and_yield(
          RuntimeError.new('This is an error'))
      end

      it { expect { subject }.to raise_error(RuntimeError, 'This is an error') }
    end

    context 'when there is no error' do
      before { Upload.any_instance.stub(:upload!).and_yield(nil) }
      its(:result) { should == [:deliver, nil] }
    end
  end

  describe '#promise_copy_out' do
    subject do
      promise = staging_task.promise_copy_out
      promise.resolve
      promise
    end

    it 'should send copying out request' do
      staging_task.should_receive(:copy_out_request).with('/tmp/droplet.tgz', /.{5,}/)
      subject
    end
  end

  describe '#promise_save_droplet' do
    subject do
      promise = staging_task.promise_save_droplet
      promise.resolve
      promise
    end

    let(:droplet) { double(:droplet) }
    let(:droplet_sha) { Digest::SHA1.file(__FILE__).hexdigest }

    before do
      staging_task.workspace.stub(:staged_droplet_path) { __FILE__ }
      bootstrap.stub(:droplet_registry) do
        {
          droplet_sha => droplet
        }
      end
    end

    it 'saves droplet and droplet sha' do
      droplet.should_receive(:local_copy).and_yield(nil)
      subject
      staging_task.droplet_sha1.should eq (droplet_sha)
    end
  end

  describe '#promise_copy_out_buildpack_cache' do
    subject do
      promise = staging_task.promise_copy_out_buildpack_cache
      promise.resolve
      promise
    end

    it 'should send copying out request' do
      staging_task.should_receive(:copy_out_request).with('/tmp/buildpack_cache.tgz', /.{5,}/)
      subject
    end
  end

  describe '#promise_task_log' do
    subject do
      promise = staging_task.promise_task_log
      promise.resolve
      promise
    end

    it 'should send copying out request' do
      staging_task.should_receive(:copy_out_request).with('/tmp/staged/logs/staging_task.log', /#{workspace_dir}/)
      subject
    end
  end

  describe '#promise_staging_info' do
    subject do
      promise = staging_task.promise_staging_info
      promise.resolve
      promise
    end

    it 'should send copying out request' do
      staging_task.should_receive(:copy_out_request).with('/tmp/staged/staging_info.yml', /#{workspace_dir}/)
      subject
    end
  end

  describe '#snapshot_attributes' do
    let(:services) {
      [
        {'credentials' => {}, 'syslog_drain_url' => 'abc'},
        {'credentials' => {}, 'syslog_drain_url' => 'def'},
      ]
    }
    let(:attributes) do
      attributes = valid_staging_attributes
      attributes['properties']['services'] = services
      attributes
    end

    it 'includes staging message' do
      expect(staging_task.snapshot_attributes['staging_message']).to eq(staging_message.to_hash)
    end

    it 'includes warden_container_path' do
      expect(staging_task.snapshot_attributes['warden_container_path']).to eq(staging_task.container.path)
    end

    it 'includes warden_job_id' do
      expect(staging_task.snapshot_attributes).to include('warden_job_id')
    end

    it 'includes syslog drain urls' do
      expect(staging_task.snapshot_attributes['syslog_drain_urls']).to eq(['abc', 'def'])
    end
  end

  describe '#warden_handle' do
    it 'gets the warden container handle' do
      expect(staging_task.container).to receive(:handle).and_return('container_handle')
      expect(staging_task.warden_handle).to eq('container_handle')
    end
  end

  def normalize_whitespace(script)
    script.gsub(/\s+/, ' ')
  end
end
