require "spec_helper"
require "dea/starting/instance"
require "dea/starting/win_instance"

describe Dea::Instance do
  include_context "tmpdir"

  let(:connection) { double("connection", :promise_call => delivering_promise) }
  let(:bootstrap) do
    double("bootstrap", :config => {})
  end
  before do
    bootstrap.config.stub(:crashes_path).and_return("crashes/path")
  end

  subject(:instance) do
    Dea::Instance.new(bootstrap, valid_instance_attributes)
  end

  subject(:wininstance) do
    Dea::WinInstance.new(bootstrap, valid_instance_attributes)
  end

  describe "default attributes" do
    it "defaults exit status to -1" do
      expect(instance.exit_status).to eq(-1)
    end
  end

  describe "attributes from start message" do
    let(:start_message) do
      message = double("message")

      # Fixture to make sure Dea::Instance.create_from_message doesn't throw up
      defaults = {
        "index" => 0,
        "droplet" => 1,
      }

      message.stub(:data).and_return(defaults.merge(start_message_data))
      message
    end

    subject(:instance) do
      Dea::Instance.new(bootstrap, start_message.data)
    end

    describe "instance attributes" do
      let(:start_message_data) do
        {
          "index" => 37,
        }
      end

      its(:instance_id) { should be }
      its(:instance_index) { should == 37 }
    end

    describe "application attributes" do
      let(:start_message_data) do
        {
          "droplet" => 37,
          "version" => "some_version",
          "name" => "my_application",
          "uris" => ["foo.com", "bar.com"],
          "users" => ["john@doe.com"],
        }
      end

      its(:application_id) { should == "37" }
      its(:application_version) { should == "some_version" }
      its(:application_name) { should == "my_application" }
      its(:application_uris) { should == ["foo.com", "bar.com"] }
    end

    describe "instance data from message data" do
      let(:start_message_data) do
        {
          "droplet" => 37
        }
      end

      its(:application_id) { should == "37" }
    end

    describe "droplet attributes" do
      let(:start_message_data) do
        {
          "sha1"           => "deadbeef",
          "executableUri"  => "http://foo.com/file.ext",
        }
      end

      its(:droplet_sha1) { should == "deadbeef" }
      its(:droplet_uri)  { should == "http://foo.com/file.ext" }
    end

    describe "start_command from message data" do
      let(:start_message_data) do
        {
          "start_command" => "start command"
        }
      end

      its(:start_command) { should == "start command" }

      context "when the value is nil" do
        let(:start_message_data) do
          {
            "start_command" => nil
          }
        end

        its(:start_command) { should be_nil }
      end

      context "when the key is not present" do
        let(:start_message_data) do
          {
          }
        end

        its(:start_command) { should be_nil }
      end
    end

    describe "other attributes" do
      let(:start_message_data) do
        {
          "limits"   => { "mem" => 1, "disk" => 2, "fds" => 3 },
          "env"      => ["FOO=BAR", "BAR=", "QUX"],
          "services" => { "name" => "redis", "type" => "redis" },
        }
      end

      its(:limits)      { should == { "mem" => 1, "disk" => 2, "fds" => 3 } }
      its(:environment) { should == { "FOO" => "BAR", "BAR" => "", "QUX" => "" } }
      its(:services)    { should == { "name" => "redis", "type" => "redis" } }
    end
  end

  describe "attributes from snapshot" do
    describe "container attributes" do
      let(:attributes) do
        valid_instance_attributes.merge(
          "warden_handle" => "abc",
          "instance_host_port" => 1234,
          "instance_container_port" => 5678,
        )
      end

      subject { described_class.new(bootstrap, attributes) }

      its(:warden_handle) { should == "abc" }
      its(:instance_host_port) { should == 1234 }
      its(:instance_container_port) { should == 5678 }
    end
  end

  describe "resource limits" do
    it "exports the memory limit in bytes" do
      instance.memory_limit_in_bytes.should == 512 * 1024 * 1024
    end

    it "exports the disk limit in bytes" do
      instance.disk_limit_in_bytes.should == 128 * 1024 * 1024
    end

    it "exports the file descriptor limit" do
      instance.file_descriptor_limit.should == 5000
    end
  end

  describe "validation" do
    it "should not raise when the attributes are valid" do
      instance = Dea::Instance.new(bootstrap, valid_instance_attributes)

      expect { instance.validate }.to_not raise_error
    end

    it "should raise when attributes are missing" do
      attributes = valid_instance_attributes.dup
      attributes.delete("application_id")
      attributes.delete("droplet")
      instance = Dea::Instance.new(bootstrap, attributes)

      expect { instance.validate }.to raise_error
    end

    it "should raise when attributes are invalid" do
      attributes = valid_instance_attributes.dup
      attributes["application_id"] = attributes["application_id"].to_i
      instance = Dea::Instance.new(bootstrap, attributes)

      expect { instance.validate }.to raise_error
    end
  end

  describe "state=" do
    it "should set state_timestamp when invoked" do
      old_timestamp = instance.state_timestamp
      instance.state = Dea::Instance::State::RUNNING
      instance.state_timestamp.should >= old_timestamp
    end
  end

  describe "consuming_memory?" do
    states = Dea::Instance::State

    [states::BORN, states::STARTING, states::RUNNING,
     states::STOPPING].each do |state|
      context "when the state is #{state}" do
        before { instance.state = state }

        it "returns true" do
          instance.consuming_memory?.should be_true
        end
      end
    end

    [states::STOPPED, states::CRASHED, states::DELETED,
     states::RESUMING].each do |state|
      context "when the state is #{state}" do
        before { instance.state = state }

        it "returns false" do
          instance.consuming_memory?.should be_false
        end
      end
    end
  end

  describe "consuming_disk?" do
    states = Dea::Instance::State

    [states::BORN, states::STARTING, states::RUNNING,
     states::STOPPING, states::CRASHED].each do |state|
      context "when the state is #{state}" do
        before { instance.state = state }

        it "returns true" do
          instance.consuming_disk?.should be_true
        end
      end
    end

    [states::STOPPED, states::DELETED, states::RESUMING].each do |state|
      context "when the state is #{state}" do
        before { instance.state = state }

        it "returns false" do
          instance.consuming_disk?.should be_false
        end
      end
    end
  end

  describe "predicate methods" do
    it "should be present for each state" do
      instance = Dea::Instance.new(bootstrap, {})
      instance.state = "invalid"

      Dea::Instance::State.constants do |state|
        predicate = "#{state.downcase.to_s}?"

        instance.send(predicate).should be_false
        instance.state = Dea::Instance::State.const_get(state)
        instance.send(predicate).should be_true
      end
    end
  end

  describe "stat collector" do
    before do
      instance.setup_stat_collector

      instance.stat_collector.stub(:start)
      instance.stat_collector.stub(:stop)

      instance.state = Dea::Instance::State::STARTING
    end

    [
      Dea::Instance::State::RESUMING,
      Dea::Instance::State::STARTING,
    ].each do |state|
      it "starts when moving from #{state.inspect} to #{Dea::Instance::State::RUNNING.inspect}" do
        instance.stat_collector.should_receive(:start)
        instance.state = state

        instance.state = Dea::Instance::State::RUNNING
      end
    end

    describe "when started" do
      [
        Dea::Instance::State::STOPPING,
        Dea::Instance::State::CRASHED,
      ].each do |state|
        it "stops when the instance moves to the #{state.inspect} state" do
          instance.stat_collector.should_receive(:stop)
          instance.state = Dea::Instance::State::RUNNING

          instance.state = state
        end
      end
    end
  end

  describe "attributes_and_stats from stat collector" do
    it "returns the used_memory_in_bytes stat in the attributes_and_stats hash" do
      instance.stat_collector.stub(:used_memory_in_bytes).and_return(28 * 1024)
      instance.attributes_and_stats.should include("used_memory_in_bytes" => 28)
    end

    it "returns the used_disk_in_bytes stat in the attributes_and_stats hash" do
      instance.stat_collector.stub(:used_disk_in_bytes).and_return(40)
      instance.attributes_and_stats.should include("used_disk_in_bytes" => 40)
    end

    it "returns the computed_pcpu stat in the attributes_and_stats hash" do
      instance.stat_collector.stub(:computed_pcpu).and_return(0.123)
      instance.attributes_and_stats.should include("computed_pcpu" => 0.123)
    end
  end

  describe "#promise_health_check unit test" do
    #let(:info_response) do
    #  info_response = double("InfoResponse")
    #  info_response.stub(:container_path).and_return("fake/container/path")
    #  info_response.stub(:host_ip).and_return("fancy ip")
    #  info_response
    #end

    let(:container_path) { "fake/container/path" }

    before do
      instance.attributes["application_uris"] = []
      instance.container.handle = "fake handle"
    end

    it "updates the path and host ip" do
      instance.container.should_receive(:update_path_and_ip) do
        instance.container.stub(path: container_path)
        instance.container.stub(host_ip: "fancy ip")
      end
      instance.should_receive(:promise_read_instance_manifest).with(container_path).and_return(delivering_promise(nil))

      instance.promise_health_check.resolve
      expect(instance.container.path).to eq(container_path)
      expect(instance.container.host_ip).to eq("fancy ip")
    end
  end

  describe "#promise_health_check" do
    let(:info_response) do
      info_response = double("InfoResponse")
      info_response.stub(:container_path).and_return("/")
      info_response.stub(:host_ip).and_return("127.0.0.1")
      info_response
    end

    let(:deferrable) do
      ::EM::DefaultDeferrable.new
    end

    before do
      bootstrap.stub(:local_ip).and_return("127.0.0.1")
      #instance.container.stub(:info).and_return(info_response)
      instance.container.stub(:update_path_and_ip)
      instance.container.stub(:host_ip).and_return(info_response.host_ip)
      instance.container.stub(:path).and_return(info_response.container_path)
      instance.stub(:promise_read_instance_manifest).and_return(delivering_promise({}))
      instance.stub(:instance_host_port).and_return(1234)
    end

    def execute_health_check
      error = result = nil

      em do
        Dea::Promise.resolve(instance.promise_health_check) do |error_, result_|
          error, result = error_, result_
          done
        end

        yield if block_given?
      end

      expect do
        raise error if error
      end

      result
    end

    shared_examples "sets timeout" do
      it "sets timeout" do
        deferrable.should_receive(:timeout)
        execute_health_check do
          deferrable.succeed
        end
      end
    end

    describe "via state file" do
      before do
        instance.stub(:promise_read_instance_manifest).and_return(delivering_promise({ "state_file" => "state_file.yml" }))
        Dea::HealthCheck::StateFileReady.stub(:new).and_yield(deferrable)
      end

      it "sets a timeout of 5 minutes" do
        deferrable.should_receive(:timeout).with(60 * 5)
        execute_health_check do
          deferrable.succeed
        end
      end

      it "can succeed" do
        result = execute_health_check do
          deferrable.succeed
        end

        result.should be_true
      end

      it "can fail" do
        result = execute_health_check do
          deferrable.fail
        end

        result.should be_false
      end
    end

    describe "when the application has URIs" do
      before do
        instance.attributes["application_uris"] = ["some-test-app.my-cloudfoundry.com"]
        Dea::HealthCheck::PortOpen.stub(:new).and_yield(deferrable)
      end

      it "defaults to 60 seconds timeout" do
        deferrable.should_receive(:timeout).with(60)
        execute_health_check do
          deferrable.succeed
        end
      end

      it "has a configurable timeout" do
        bootstrap.config["maximum_health_check_timeout"] = 100
        deferrable.should_receive(:timeout).with(100)
        execute_health_check do
          deferrable.succeed
        end
      end

      it "succeeds when the port is open" do
        result = execute_health_check do
          deferrable.succeed
        end

        result.should be_true
      end

      it "fails when the port is not open" do
        result = execute_health_check do
          deferrable.fail
        end

        result.should be_false
      end
    end

    describe "when the application does not have any URIs" do
      before { instance.attributes["application_uris"] = [] }

      it "should succeed" do
        result = execute_health_check
        result.should be_true
      end
    end

    context "when failing to check the health" do
      let(:error) { RuntimeError.new("Some Error in warden") }

      before { instance.container.stub(:update_path_and_ip).and_raise(error) }

      subject { Dea::Promise.resolve(instance.promise_health_check) }

      it "doesn't raise an error" do
        expect {
          subject
        }.to_not raise_error
      end

      it "should log the failure" do
        instance.instance_variable_get(:@logger).should_receive(:error)
        subject
      end
    end
  end

  describe "start transition" do
    let(:droplet) do
      droplet = double("droplet")
      droplet.stub(:droplet_dirname).and_return(File.join(tmpdir, "droplet", "some_sha1"))
      droplet.stub(:droplet_basename).and_return("droplet.tgz")
      droplet.stub(:droplet_path).and_return(File.join(droplet.droplet_dirname, droplet.droplet_basename))
      droplet
    end

    let(:warden_connection) { double("warden_connection") }

    before do
      bootstrap.stub(:config).and_return({ "bind_mounts" => [] })
      instance.stub(:promise_droplet).and_return(delivering_promise)
      instance.container.stub(:get_connection).and_raise("bad connection bad")
      instance.container.stub(:create_container)
      instance.stub(:promise_setup_network).and_return(delivering_promise)
      instance.stub(:promise_limit_disk).and_return(delivering_promise)
      instance.stub(:promise_limit_memory).and_return(delivering_promise)
      instance.stub(:promise_setup_environment).and_return(delivering_promise)
      instance.stub(:promise_extract_droplet).and_return(delivering_promise)
      instance.stub(:promise_prepare_start_script).and_return(delivering_promise)
      instance.stub(:promise_exec_hook_script).with('before_start').and_return(delivering_promise)
      instance.stub(:promise_start).and_return(delivering_promise)
      instance.stub(:promise_exec_hook_script).with('after_start').and_return(delivering_promise)
      instance.stub(:promise_health_check).and_return(delivering_promise(true))
      instance.stub(:droplet).and_return(droplet)
      instance.stub(:start_stat_collector)
      instance.stub(:link)

      wininstance.stub(:promise_droplet).and_return(delivering_promise)
      wininstance.container.stub(:get_connection).and_raise("bad connection bad")
      wininstance.container.stub(:create_container)
      wininstance.stub(:promise_setup_network).and_return(delivering_promise)
      wininstance.stub(:promise_limit_disk).and_return(delivering_promise)
      wininstance.stub(:promise_limit_memory).and_return(delivering_promise)
      wininstance.stub(:promise_setup_environment).and_return(delivering_promise)
      wininstance.stub(:promise_extract_droplet).and_return(delivering_promise)
      wininstance.stub(:promise_prepare_start_script).and_return(delivering_promise)
      wininstance.stub(:promise_exec_hook_script).with('before_start').and_return(delivering_promise)
      wininstance.stub(:promise_start).and_return(delivering_promise)
      wininstance.stub(:promise_exec_hook_script).with('after_start').and_return(delivering_promise)
      wininstance.stub(:promise_health_check).and_return(delivering_promise(true))
      wininstance.stub(:droplet).and_return(droplet)
      wininstance.stub(:start_stat_collector)
      wininstance.stub(:link)
    end

    def expect_start
      error = nil

      em do
        instance.start do |error_|
          error = error_
          done
        end
      end

      expect do
        raise error if error
      end
    end

    def win_expect_start
      error = nil

      em do
        wininstance.start do |error_|
          error = error_
          done
        end
      end

      expect do
        raise error if error
      end
    end

    describe "checking source state" do
      passing_states = [Dea::Instance::State::BORN]

      passing_states.each do |state|
        it "passes when #{state.inspect}" do
          instance.state = state
          expect_start.to_not raise_error
        end
      end

      Dea::Instance::State.constants.map do |constant|
        Dea::Instance::State.const_get(constant)
      end.each do |state|
        next if passing_states.include?(state)

        it "fails when #{state.inspect}" do
          instance.state = state
          expect_start.to raise_error(Dea::Instance::BaseError, /transition/)
        end
      end
    end

    describe "downloading droplet" do
      before { instance.unstub(:promise_droplet) }

      it "succeeds when #download succeeds" do
        droplet.stub(:download).and_yield(nil)

        expect_start.to_not raise_error
        instance.exit_description.should be_empty
      end

      it "fails when #download fails" do
        msg = "download failed"
        droplet.stub(:download).and_yield(Dea::Instance::BaseError.new(msg))

        expect_start.to raise_error(Dea::Instance::BaseError, msg)
      end
    end

    describe "creating warden container" do
      let(:promise) { double(:creating_container_promise, resolve: nil)}

      it "succeeds when the call succeeds" do
        instance.config["bind_mounts"] = [{'src_path' => '/var/src/', 'dst_path' => '/var/dst'}]

        expected_bind_mounts = [
          {'src_path' => droplet.droplet_dirname, 'dst_path' => droplet.droplet_dirname },
          {'src_path' => '/var/src/', 'dst_path' => '/var/dst'}
        ]
        with_network = true
        instance.container.should_receive(:create_container).
          with(expected_bind_mounts, instance.disk_limit_in_bytes, instance.memory_limit_in_bytes, with_network)
        expect_start.to_not raise_error
        instance.exit_description.should be_empty
      end

      it "fails when the call fails" do
        msg = "promise warden call error for container creation"

        instance.container.should_receive(:create_container).and_raise(RuntimeError.new(msg))

        expect_start.to raise_error(RuntimeError, /error/i)
      end

      it "saves the created container's handle on attributes" do
        instance.container.stub(:create_container) do
          instance.container.handle = "some-handle"
        end

        expect {
          expect_start.to_not raise_error
        }.to change {
          instance.attributes["warden_handle"]
        }.from(nil).to("some-handle")
      end
    end

    describe "extracting the droplet" do
      before do
        instance.unstub(:promise_extract_droplet)
      end

      it "should run tar" do
        instance.container.stub(:run_script) do |_, script|
          script.should =~ /tar zxf/
        end

        expect_start.to_not raise_error
        instance.exit_description.should be_empty
      end

      it "should run tar on windows" do
        wininstance.container.stub(:run_script) do |_, script|
          script.should =~ /\"cmd\":\"tar\"/
        end

        win_expect_start.to_not raise_error
        wininstance.exit_description.should be_empty
      end

      it "can fail by run failing" do
        msg = "droplet extraction failure"
        instance.container.stub(:run_script) do |*_|
          raise RuntimeError.new(msg)
        end

        expect_start.to raise_error(msg)
      end
    end

    describe "setting up environment" do
      before do
        instance.unstub(:promise_setup_environment)
      end

      it "should create the app dir" do
        instance.container.stub(:run_script) do |_, script|
          script.should =~ %r{mkdir -p home/vcap/app}
        end

        expect_start.to_not raise_error
        instance.exit_description.should be_empty
      end

      it "should create the app dir on windows" do
        wininstance.container.stub(:run_script) do |_, script|
          script.should =~ %r{"cmd":"mkdir","args":\["@ROOT@/app"\]}
        end

        win_expect_start.to_not raise_error
        wininstance.exit_description.should be_empty
      end

      it "should chown the app dir", unix_only: true do
        instance.container.stub(:run_script) do |_, script|
          script.should =~ %r{chown vcap:vcap home/vcap/app}
        end

        expect_start.to_not raise_error
        instance.exit_description.should be_empty
      end

      it "should symlink the app dir" do
        instance.container.stub(:run_script) do |_, script|
          script.should =~ %r{ln -s home/vcap/app /app}
        end

        expect_start.to_not raise_error
        instance.exit_description.should be_empty
      end

      it "should symlink the app dir on windows" do
        wininstance.container.stub(:run_script) do |_, script|
          script.should =~ %r{@ROOT@/app}
        end

        win_expect_start.to_not raise_error
        wininstance.exit_description.should be_empty
      end

      it "can fail by run failing" do
        msg = "environment setup failure"

        instance.container.stub(:run_script) do |*_|
          raise RuntimeError.new(msg)
        end

        expect_start.to raise_error(msg)
      end
    end

    shared_examples_for "start script hook" do |hook|
      describe "#{hook} hook" do
        let(:runtime) do
          runtime = double(:runtime)
          runtime.stub(:environment).and_return({})
          runtime
        end

        before do
          bootstrap.stub(:config).and_return("hooks" => { hook => fixture("hooks/#{hook}") })
          instance.stub(:runtime).and_return(runtime)
          instance.unstub(:promise_exec_hook_script)
        end

        it "should execute script file" do
          script_content = nil
          instance.container.stub(:run_script) do |_, script|
            script.should_not be_empty
            lines = script.split("\n")
            script_content = lines[-2]
          end

          expect_start.to_not raise_error
          instance.exit_description.should be_empty

          script_content.should == "echo \"#{hook}\""
        end

        it "should raise error when script execution fails" do
          msg = "script execution failed"

          instance.container.stub(:run_script) do |_, script|
            raise RuntimeError.new(msg)
          end

          expect_start.to raise_error(msg)
        end
      end
    end

    it_behaves_like 'start script hook', 'before_start'
    it_behaves_like 'start script hook', 'after_start'

    shared_examples_for "start script hook on windows" do |hook|
      describe "#{hook} hook" do
        let(:runtime) do
          runtime = double(:runtime)
          runtime.stub(:environment).and_return({})
          runtime
        end

        before do
          bootstrap.stub(:config).and_return("hooks" => { hook => fixture("hooks/#{hook}") })
          wininstance.stub(:runtime).and_return(runtime)
          wininstance.unstub(:promise_exec_hook_script)
        end

        it "should execute script file" do
          script_content = nil
          wininstance.container.stub(:run_script) do |_, script|
            script.should_not be_empty
            script_content = script
          end

          win_expect_start.to_not raise_error
          wininstance.exit_description.should be_empty

          script_content.should include("echo \\\"#{hook}\\\"")
        end

        it "should raise error when script execution fails" do
          msg = "script execution failed"

          wininstance.container.stub(:run_script) do |_, script|
            raise RuntimeError.new(msg)
          end

          win_expect_start.to raise_error(msg)
        end
      end
    end

    it_behaves_like 'start script hook on windows', 'before_start'
    it_behaves_like 'start script hook on windows', 'after_start'

    describe "#promise_start" do
      let(:response) { double("spawn_response", job_id: 37) }
      let(:env) do
        double("environment 1",
               exported_environment_variables: 'system="sytem_value";\nexport user="user_value";\n',
               exported_user_environment_variables: 'user="user_value";\n',
               exported_system_environment_variables: 'system="sytem_value";\n'
        )
      end

      before do
        instance.unstub(:promise_start)
        instance.stub(:staged_info).and_return(nil)
        instance.attributes["warden_handle"] = "handle"
        Dea::Env.stub(:new).and_return(env)

        wininstance.unstub(:promise_start)
        wininstance.stub(:staged_info).and_return(nil)
        wininstance.attributes["warden_handle"] = "handle"
        Dea::WinEnv.stub(:new).and_return(env)
      end

      it "raises errors when the request fails" do
        msg = "can't start the application"

        instance.container.should_receive(:call).and_raise(RuntimeError.new(msg))
        expect {
          instance.promise_start.resolve
        }.to raise_error(RuntimeError, msg)

        # Job ID should not be set
        expect(instance.attributes["warden_job_id"]).to be_nil
      end

      context "when there is a task info yaml in the droplet" do
        let(:script) { "./dostuffscript" }
        let(:generator) { double("script generator", generate: script) }

        before do
          instance.stub(:staged_info).and_return(
            "start_command" => "fake_start_command.sh"
          )

          wininstance.stub(:staged_info).and_return(
              "start_command" => "fake_start_command.sh"
          )
        end

        it "generates the correct script and calls promise spawn" do
          Dea::StartupScriptGenerator.should_receive(:new).with(
            "fake_start_command.sh",
            env.exported_user_environment_variables,
            env.exported_system_environment_variables
          ).and_return(generator)

          instance.container.should_receive(:spawn)
            .with(script, instance.file_descriptor_limit, Dea::Instance::NPROC_LIMIT, true)
            .and_return(response)

          instance.promise_start.resolve
        end

        it "generates the correct script and calls promise spawn on windows" do
          Dea::WinStartupScriptGenerator.should_receive(:new).with(
              "fake_start_command.sh",
              env.exported_user_environment_variables,
              env.exported_system_environment_variables
          ).and_return(generator)

          wininstance.container.should_receive(:spawn)
            .with("[{\"cmd\":\"ps1\",\"args\":[\"./dostuffscript\",\"exit\"]}]", wininstance.file_descriptor_limit, Dea::Instance::NPROC_LIMIT, true)
            .and_return(response)

          wininstance.promise_start.resolve
        end
      end

      context "when there is a custom start command set on the instance" do
        subject(:instance) do
          Dea::Instance.new(
            bootstrap,
            valid_instance_attributes.merge(
              "start_command" => "my_custom_start_command.sh")
          )
        end

        let(:script) { "./dostuffscript" }
        let(:generator) { double("script generator", generate: script) }

        def self.it_uses_the_custom_start_command
          it "uses the custom start command" do
            Dea::StartupScriptGenerator.should_receive(:new).with(
              "my_custom_start_command.sh",
              env.exported_user_environment_variables,
              env.exported_system_environment_variables
            ).and_return(generator)

            instance.container.should_receive(:spawn)
              .with(script, instance.file_descriptor_limit, Dea::Instance::NPROC_LIMIT, true)
              .and_return(response)

            instance.promise_start.resolve
          end
        end

        context "and the buildpack does not provide a command" do
          before do
            instance.stub(:staged_info).and_return("start_command" => nil)
          end

          it_uses_the_custom_start_command
        end

        context "and the buildpack provides one" do
          before do
            instance.stub(:staged_info).and_return("start_command" => "foo")
          end

          it_uses_the_custom_start_command
        end
      end

      context "when there is a staged_info but it lacks a start_command and instance lacks a start command" do
        before do
          instance.stub(:staged_info).and_return("start_command" => nil)
        end

        it "fails to start" do
          expect {
            instance.promise_start.resolve
          }.to raise_error("missing start command")
        end
      end

      context "when there is no task info yaml in the droplet only a startup script (old DEA)" do
        # TODO delete after two phase migration

        it "runs the startup script instead of generating one" do
          instance.container.should_receive(:call) do |name, request|
            expect(request.script).to include("./startup")
            response
          end

          instance.promise_start.resolve
        end

        it "runs the startup script instead of generating one on windows" do
          wininstance.container.should_receive(:call) do |name, request|
            expect(request.script).to include("./startup.ps1")
            response
          end

          wininstance.promise_start.resolve
        end
      end
    end

    describe "checking application health" do
      before :each do
        instance.
          should_receive(:promise_state).
          with(Dea::Instance::State::BORN, Dea::Instance::State::STARTING).
          and_return(delivering_promise)
      end

      it "transitions from starting to running if healthy" do
        instance.stub(:promise_health_check).and_return(delivering_promise(true))

        instance.
          should_receive(:promise_state).
          with(Dea::Instance::State::STARTING, Dea::Instance::State::RUNNING).
          and_return(delivering_promise)

        expect_start.to_not raise_error
        instance.exit_description.should be_empty
      end

      it "fails if the instance is unhealthy" do
        instance.stub(:promise_health_check).and_return(delivering_promise(false))

        expect_start.to raise_error

        # Instance exit description should be set to the failure message
        instance.exit_description.should == "failed to start accepting connections"
      end
    end

    context "when link fails" do
      before do
        instance.unstub(:link)
        instance.container.stub(:call_with_retry).with(:link, anything) do
          double("response", :exit_status => 255, :info => double("info", :events => ["out of memory"]))
        end

        instance.stub(:promise_state).and_return(delivering_promise)
      end

      it "sets exit description based on link response" do
        instance.start
        instance.exit_description.should == "out of memory"
      end
    end

    context "when an arbitrary error occurs" do
      before { instance.stub(:link) { raise "heck" } }

      it "sets a generic exit description" do
        instance.start
        instance.exit_description.should == "failed to start"
      end
    end
  end

  describe "stop transition" do
    let(:connection) { double("connection", :promise_call => delivering_promise) }

    let(:env) { double("environment").as_null_object }

    before do
      bootstrap.stub(:config).and_return({})
      instance.stub(:promise_state).and_return(delivering_promise)
      instance.container.stub(:get_connection).and_return(connection)
      instance.stub(:promise_stop).and_return(delivering_promise)
      Dea::Env.stub(:new).and_return(env)

      wininstance.stub(:promise_state).and_return(delivering_promise)
      wininstance.container.stub(:get_connection).and_return(connection)
      wininstance.stub(:promise_stop).and_return(delivering_promise)
      Dea::WinEnv.stub(:new).and_return(env)
    end

    def expect_stop
      error = nil

      em do
        instance.stop do |error_|
          error = error_
          done
        end
      end

      expect do
        raise error if error
      end
    end

    def win_expect_stop
      error = nil

      em do
        wininstance.stop do |error_|
          error = error_
          done
        end
      end

      expect do
        raise error if error
      end
    end

    describe "checking source state" do
      before do
        instance.unstub(:promise_state)
      end

      passing_states = [Dea::Instance::State::RUNNING, Dea::Instance::State::STARTING]

      passing_states.each do |state|
        it "passes when #{state.inspect}" do
          instance.state = state
          expect_stop.to_not raise_error
        end
      end

      Dea::Instance::State.constants.map do |constant|
        Dea::Instance::State.const_get(constant)
      end.each do |state|
        next if passing_states.include?(state)

        it "fails when #{state.inspect}" do
          instance.state = state
          expect_stop.to raise_error(Dea::Instance::BaseError, /transition/)
        end
      end
    end

    shared_examples_for "stop script hook" do |hook|
      describe "script hook" do
        let(:runtime) do
          runtime = double(:runtime)
          runtime.stub(:environment).and_return({})
          runtime
        end

        let(:env) { double("environment", exported_environment_variables: "export A=B;\n") }

        before do
          Dea::Env.stub(:new).with(instance).and_return(env)
          bootstrap.stub(:config).and_return("hooks" => { hook => fixture("hooks/#{hook}") })
        end

        it "executes the #{hook} script file" do
          script_content = nil
          instance.container.stub(:run_script) do |_, script|
            lines = script.split("\n")
            script_content = lines[-2]
          end
          expect_stop.to_not raise_error
          script_content.should == "echo \"#{hook}\""
        end

        it "exports the variables in the hook files" do
          actual_script_content = nil
          instance.container.stub(:run_script) do |_, script|
            actual_script_content = script
          end
          expect_stop.to_not raise_error
          actual_script_content.should match /export A=B/
        end
      end
    end

    it_behaves_like 'stop script hook', 'before_stop'
    it_behaves_like 'stop script hook', 'after_stop'

    shared_examples_for "stop script hook on windows" do |hook|
      describe "script hook" do
        let(:runtime) do
          runtime = mock(:runtime)
          runtime.stub(:environment).and_return({})
          runtime
        end

        let(:env) { double("environment", exported_environment_variables: "export A=B;\n") }

        before do
          Dea::Env.stub(:new).with(instance).and_return(env)
          bootstrap.stub(:config).and_return("hooks" => { hook => fixture("hooks/#{hook}") })
        end

        it "executes the #{hook} script file" do
          script_content = nil
          wininstance.container.stub(:run_script) do |_, script|
            script_content = script
          end
          win_expect_stop.to_not raise_error
          script_content.should include("echo \\\"#{hook}\\\"")
        end

        it "exports the variables in the hook files" do
          actual_script_content = nil
          wininstance.container.stub(:run_script) do |_, script|
            actual_script_content = script
          end
          win_expect_stop.to_not raise_error
          actual_script_content.should match /export A=B/
        end
      end
    end

    it_behaves_like 'stop script hook on windows', 'before_stop'
    it_behaves_like 'stop script hook on windows', 'after_stop'
  end

  describe "#promise_link" do
    let(:exit_status) { 42 }
    let(:info_events) { [] }

    let(:info_response) do
      double("Warden::Protocol::InfoResponse").tap do |info|
        info.stub(:events).and_return(info_events)
      end
    end

    let(:response) do
      response = double("Warden::Protocol::LinkResponse")
      response.stub(:exit_status).and_return(exit_status)
      response.stub(:info).and_return(info_response)
      response
    end

    describe "when the LinkRequest fails" do
      it "propagates the exception" do
        instance.container.should_receive(:call_with_retry).and_raise(RuntimeError, /error/i)

        expect {
          instance.promise_link.resolve
        }.to raise_error(RuntimeError, /error/i)
      end

      it "causes the promise to fail, for the resolver of the promise (sanity check)" do
        instance.container.should_receive(:call_with_retry).and_raise(RuntimeError.new("error"))
        instance.link
        expect(instance.exit_status).to eq(-1)
      end
    end

    describe "when the LinkRequest completes successfully" do
      let(:exit_status) { 42 }

      before do
        instance.container.stub(:call_with_retry).and_return(response)
      end

      it "executes a LinkRequest with the warden handle and job ID and returns response" do
        instance.container.handle = "handle"
        instance.attributes["warden_job_id"] = "1"
        instance.container.should_receive(:call_with_retry) do |name, request|
          expect(name).to eq(:link)
          expect(request).to be_kind_of(::Warden::Protocol::LinkRequest)
          expect(request.handle).to eq("handle")
          expect(request.job_id).to eq("1")

          response
        end

        result = instance.promise_link.resolve
        expect(result).to eq(response)
      end
    end
  end

  describe "#link" do
    let(:exit_status) { 42 }
    let(:info_events) { nil }

    let(:info_response) do
      double("Warden::Protocol::InfoResponse").tap do |info|
        info.stub(:events).and_return(info_events)
      end
    end

    let(:response) do
      response = double("Warden::Protocol::LinkResponse")
      response.stub(:exit_status).and_return(exit_status)
      response.stub(:info).and_return(info_response)
      response
    end

    before do
      instance.state = Dea::Instance::State::RUNNING
      instance.container.stub(:get_connection).and_return(connection)
      instance.stub(:promise_link).and_return(delivering_promise(response))
      expect(instance.exit_status).to eq(-1)
      expect(instance.exit_description).to eq("")
    end

    [
      Dea::Instance::State::RESUMING,
    ].each do |state|
      it "is triggered link when transitioning from #{state.inspect}" do
        instance.state = state
        instance.setup_link

        instance.should_receive(:link)
        instance.state = Dea::Instance::State::RUNNING
      end
    end

    describe "when #promise_link succeeds" do
      it "sets the exit status on the instance" do
        instance.link
        expect(instance.exit_status).to eq(exit_status)
      end

      context "when the container_info has an event" do
        let(:info_events) { ["some weird thing happened"] }

        it "sets the exit_description to the text of the event" do
          instance.link
          expect(instance.exit_description).to eq("some weird thing happened")
        end
      end

      context "when the info_response is missing" do
        let(:info_response) { nil }

        it "sets the exit_description to 'cannot be determined'" do
          instance.link
          expect(instance.exit_description).to eq("cannot be determined")
        end
      end

      context "when there is an info_response no usable information" do
        it "sets the exit_description to 'out of memory'" do
          instance.link
          expect(instance.exit_description).to eq("app instance exited")
        end
      end
    end

    context "when the #promise_link fails" do
      before do
        instance.should_receive(:promise_link).and_return(failing_promise(RuntimeError.new("error")))
      end

      it "sets exit status of the instance to -1" do
        instance.link
        expect(instance.exit_status).to eq(-1)
      end

      it "sets exit description of the instance to unknown" do
        instance.link
        expect(instance.exit_description).to eq("unknown")
      end
    end

    describe "state transitions" do
      [
        Dea::Instance::State::STARTING,
        Dea::Instance::State::RUNNING,
      ].each do |from|
        to = Dea::Instance::State::CRASHED

        it "changes to #{to.inspect} when it was #{from.inspect}" do
          instance.state = from

          expect {
            instance.link
          }.to change(instance, :state).to(to)
        end
      end

      [
        Dea::Instance::State::STOPPING,
        Dea::Instance::State::STOPPED,
      ].each do |from|
        it "doesn't change when it was #{from.inspect}" do
          instance.state = from

          expect {
            instance.link
          }.to_not change(instance, :state)
        end
      end
    end
  end

  describe "destroy" do
    subject(:instance) do
      Dea::Instance.new(bootstrap, valid_instance_attributes)
    end

    let(:connection) { double("connection", :promise_call => delivering_promise) }

    before do
      instance.container.stub(:get_connection).and_return(connection)
    end

    def expect_destroy
      error = nil

      em do
        instance.destroy do |error_|
          error = error_
          done
        end
      end

      expect do
        raise error if error
      end
    end

    describe "#promise_destroy" do
      it "executes a DestroyRequest" do
        instance.container.handle = "handle"

        instance.container.should_receive(:call_with_retry) do |_, request|
          request.should be_kind_of(::Warden::Protocol::DestroyRequest)
          request.handle.should == "handle"
        end

        expect_destroy.to_not raise_error
      end
    end
  end

  describe "health checks" do
    let(:instance) do
      Dea::Instance.new(bootstrap, valid_instance_attributes)
    end

    let(:manifest_path) do
      File.join(tmpdir, "rootfs", "home", "vcap", "droplet.yaml")
    end

    before :each do
      FileUtils.mkdir_p(File.dirname(manifest_path))
    end

    describe "#promise_read_instance_manifest" do
      it "delivers {} if no container path is returned" do
        instance.promise_read_instance_manifest(nil).resolve.should == {}
      end

      it "delivers {} if the manifest path doesn't exist" do
        instance.promise_read_instance_manifest(tmpdir).resolve.should == {}
      end

      it "delivers the parsed manifest if the path exists" do
        manifest = { "test" => "manifest" }
        File.open(manifest_path, "w+") { |f| YAML.dump(manifest, f) }

        instance.promise_read_instance_manifest(tmpdir).resolve.should == manifest
      end
    end
  end

  describe "crash handler" do
    before do
      instance.setup_crash_handler
      instance.state = Dea::Instance::State::RUNNING
      instance.stub(:promise_copy_out).and_return(delivering_promise)
      instance.stub(:promise_destroy).and_return(delivering_promise)
    end

    def expect_crash_handler
      error = nil

      em do
        instance.crash_handler do |error_|
          error = error_
          done
        end
      end

      expect do
        raise error if error
      end
    end

    [Dea::Instance::State::RESUMING,
     Dea::Instance::State::RUNNING,
    ].each do |state|
      it "is triggered link when transitioning from #{state.inspect}" do
        instance.state = state

        instance.should_receive(:crash_handler)
        instance.state = Dea::Instance::State::CRASHED
      end
    end

    describe "when triggered" do
      before do
        instance.container.handle = "handle"
      end

      it "should resolve #promise_copy_out" do
        instance.should_receive(:promise_copy_out).and_return(delivering_promise)
        expect_crash_handler.to_not raise_error
      end

      it "should resolve #promise_destroy" do
        instance.should_receive(:promise_destroy).and_return(delivering_promise)
        expect_crash_handler.to_not raise_error
      end

      it "should close warden connections" do
        instance.container.should_receive(:close_all_connections)

        expect_crash_handler.to_not raise_error
      end
    end

    describe "#promise_copy_out" do
      before do
        instance.unstub(:promise_copy_out)
      end

      it "should copy the contents of a directory" do
        instance.container.should_receive(:call_with_retry) do |_, request|
          request.src_path.should =~ %r!/$!
        end

        instance.promise_copy_out.resolve
      end
    end
  end

  describe "#staged_info" do
    before do
      instance.stub(:copy_out_request)
    end

    context "when the files does exist" do
      before do
        YAML.stub(:load_file).and_return(a: 1)
        File.stub(:exists?).
          with(match(/staging_info\.yml/)).
          and_return(true)
      end

      it "sends copying out request" do
        instance.should_receive(:copy_out_request).with("/home/vcap/staging_info.yml", instance_of(String))
        instance.staged_info
      end

      it "sends copying out request on windows" do
        wininstance.should_receive(:copy_out_request).with("@ROOT@/staging_info.yml", instance_of(String))
        wininstance.staged_info
      end

      it "reads the file from the copy out" do
        YAML.should_receive(:load_file).with(/.+staging_info\.yml/)
        expect(instance.staged_info).to eq(a: 1)
      end

      it "should only be called once" do
        YAML.should_receive(:load_file).once
        instance.staged_info
        instance.staged_info
      end
    end

    context "when the yaml file does not exist" do
      it "returns nil" do
        expect(instance.staged_info).to be_nil
      end
    end

    it "doesn't pollute the temp directory" do
      tmpdir = Dir.tmpdir

      old_size = Dir.glob(File.join(tmpdir, "**", "*"), File::FNM_DOTMATCH).size
      instance.staged_info

      expect(Dir.glob(File.join(tmpdir, "**", "*"), File::FNM_DOTMATCH).size).to be <= old_size
    end
  end

  describe "#instance_path" do
    context "when state is CRASHED" do
      before {
        instance.state = Dea::Instance::State::CRASHED
        wininstance.state = Dea::Instance::State::CRASHED
      }

      context "when warden_container_path is set" do
        before {
          instance.container.stub(:path => "/root/dir")
          wininstance.container.stub(:path => "/root/dir")
        }

        it "returns container path", unix_only:true do
          expect(instance.instance_path).to eq("/root/dir/tmp/rootfs/home/vcap")
        end

        it "returns container path on windows", windows_only:true do
          expect(wininstance.instance_path).to eq("C:/root/dir")
        end
      end



      context "when warden_container_path is not set" do
        it "raises" do
          expect {
            instance.instance_path
          }.to raise_error("Warden container path not present")
        end
      end
    end

    context "when state is RUNNING" do
      before {
        instance.state = Dea::Instance::State::RUNNING
        wininstance.state = Dea::Instance::State::RUNNING
      }
      context "when warden_container_path is set" do
        before {
          instance.container.stub(:path => "/root/dir")
          wininstance.container.stub(:path => "/root/dir")
        }

        it "returns container path", unix_only:true do
          expect(instance.instance_path).to eq("/root/dir/tmp/rootfs/home/vcap")
        end

        it "returns container path", windows_only:true do
          expect(wininstance.instance_path).to eq("C:/root/dir")
        end
      end

      context "when warden container path is not set" do
        it "raises" do
          expect {
            instance.instance_path
          }.to raise_error("Warden container path not present")
        end
      end
    end

    context "when state is STARTING" do
      before { instance.state = Dea::Instance::State::STARTING }

      it "raises" do
        expect {
          instance.instance_path
        }.to raise_error("Instance path unavailable")
      end
    end
  end

  describe "recovering from a snapshot" do
    it "sets the container's warden handle" do
      instance = described_class.new(bootstrap,
        valid_instance_attributes.merge(
          "warden_handle" => "abc"))

      expect(instance.container.handle).to eq("abc")
    end

    it "sets the container's network ports" do
      instance = described_class.new(bootstrap,
        valid_instance_attributes.merge(
          "instance_host_port" => 1234,
          "instance_container_port" => 5678))

      instance.instance_host_port.should == 1234
      instance.instance_container_port.should == 5678
    end
  end
end
