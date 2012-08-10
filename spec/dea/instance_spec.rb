# coding: UTF-8

require "spec_helper"
require "dea/instance"

describe Dea::Instance do
  include_context "tmpdir"

  let(:bootstrap) do
    mock("bootstrap")
  end

  describe "attributes from start message" do
    let(:start_message) do
      message = double("message")

      # Fixture to make sure Dea::Instance.create_from_message doesn't throw up
      defaults = {
        "index"   => 0,
        "droplet" => 1,
      }

      message.stub(:data).and_return(defaults.merge(start_message_data))
      message
    end

    subject(:instance) do
      Dea::Instance.new(bootstrap, Dea::Instance.translate_attributes(start_message.data))
    end

    describe "instance attributes" do
      let(:start_message_data) do
        {
          "index" => 37,
        }
      end

      its(:instance_id)    { should be }
      its(:instance_index) { should == 37 }
    end

    describe "application attributes" do
      let(:start_message_data) do
        {
          "droplet" => 37,
          "version" => "some_version",
          "name"    => "my_application",
          "uris"    => ["foo.com", "bar.com"],
          "users"   => ["john@doe.com"],
        }
      end


      its(:application_id)      { should == 37 }
      its(:application_version) { should == "some_version" }
      its(:application_name)    { should == "my_application" }
      its(:application_uris)    { should == ["foo.com", "bar.com"] }
      its(:application_users)   { should == ["john@doe.com"] }
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

    describe "runtime/framework attributes" do
      let(:start_message_data) do
        {
          "runtime"   => "ruby19",
          "framework" => "rails",
        }
      end

      its(:runtime_name)   { should == "ruby19" }
      its(:framework_name) { should == "rails" }
    end

    describe "other attributes" do
      let(:start_message_data) do
        {
          "limits"   => { "mem" => 1, "disk" => 2, "fds" => 3 },
          "env"      => ["FOO=BAR"],
          "services" => { "name" => "redis", "type" => "redis" },
          "flapping" => false,
          "debug"    => "debug",
          "console"  => "console",
        }
      end

      its(:limits)      { should == { "mem" => 1, "disk" => 2, "fds" => 3 } }
      its(:environment) { should == { "FOO" => "BAR" } }
      its(:services)    { should == { "name" => "redis", "type" => "redis" } }
      its(:flapping)    { should == false }
      its(:debug)       { should == "debug" }
      its(:console)     { should == "console" }
    end
  end

  describe "resource limits" do
    subject(:instance) do
      Dea::Instance.new(bootstrap, valid_instance_attributes)
    end

    it "exports the memory limit in bytes with a little bit of slack" do
      instance.memory_limit_in_bytes.should be_within(200_000).of(1_000_000)
    end

    it "exports the disk limit in bytes" do
      instance.disk_limit_in_bytes.should == 2048 * 1024
    end

    it "exports the file descriptor limit" do
      instance.file_descriptor_limit.should == 3
    end
  end

  describe "validation" do
    before do
      bootstrap.stub(:runtimes).and_return(Hash.new { |*_| "runtime" })
    end

    it "should not raise when the attributes are valid" do
      instance = Dea::Instance.new(bootstrap, valid_instance_attributes)

      expect do
        instance.validate
      end.to_not raise_error
    end

    it "should raise when attributes are missing" do
      attributes = valid_instance_attributes.dup
      attributes.delete("application_id")
      instance = Dea::Instance.new(bootstrap, attributes)

      expect do
        instance.validate
      end.to raise_error
    end

    it "should raise when attributes are invalid" do
      attributes = valid_instance_attributes.dup
      attributes["application_id"] = attributes["application_id"].to_s
      instance = Dea::Instance.new(bootstrap, attributes)

      expect do
        instance.validate
      end.to raise_error
    end

    it "should raise when the runtime is not found" do
      attributes = valid_instance_attributes.dup
      attributes["runtime_name"] = "not_found"

      instance = Dea::Instance.new(bootstrap, attributes)

      bootstrap.should_receive(:runtimes).and_return({})

      expect do
        instance.validate
      end.to raise_error(Dea::Instance::RuntimeNotFoundError)
    end
  end

  describe "state=" do
    it "should set state_timestamp when invoked" do
      instance = Dea::Instance.new(bootstrap, valid_instance_attributes)
      old_timestamp = instance.state_timestamp
      instance.state = Dea::Instance::State::RUNNING

      instance.state_timestamp.should > old_timestamp
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

  describe "collect_stats" do
    let(:info_response1) do
      mem_stat = ::Warden::Protocol::InfoResponse::MemoryStat.new(:rss => 1024)
      cpu_stat = ::Warden::Protocol::InfoResponse::CpuStat.new(:usage => 2048)
      disk_stat = ::Warden::Protocol::InfoResponse::DiskStat.new(:bytes_used => 4096)
      ::Warden::Protocol::InfoResponse.new(:events => [],
                                           :memory_stat => mem_stat,
                                           :disk_stat => disk_stat,
                                           :cpu_stat => cpu_stat)
    end

    let(:info_response2) do
      mem_stat = ::Warden::Protocol::InfoResponse::MemoryStat.new(:rss => 2048)
      cpu_stat = ::Warden::Protocol::InfoResponse::CpuStat.new(:usage => 4096)
      disk_stat = ::Warden::Protocol::InfoResponse::DiskStat.new(:bytes_used => 8192)
      ::Warden::Protocol::InfoResponse.new(:events => [],
                                           :memory_stat => mem_stat,
                                           :disk_stat => disk_stat,
                                           :cpu_stat => cpu_stat)
    end

    subject(:instance) do
      Dea::Instance.new(bootstrap, valid_instance_attributes)
    end

    it "should update memory" do
      instance.stub(:promise_container_info).and_return(delivering_promise(info_response1))
      instance.collect_stats

      instance.used_memory_in_bytes.should == info_response1.memory_stat.rss * 1024
    end

    it "should update disk" do
      instance.stub(:promise_container_info).and_return(delivering_promise(info_response1))
      instance.collect_stats

      instance.used_disk_in_bytes.should == info_response1.disk_stat.bytes_used
    end

    it "should update computed_pcpu after 2 samples have been taken" do
      [info_response1, info_response2].each do |resp|
        instance.stub(:promise_container_info).and_return(delivering_promise(resp))
        # Give some time between samples for pcpu computation
        sleep(0.001)
        instance.collect_stats
      end

      instance.computed_pcpu.should > 0
    end
  end

  describe "start transition" do
    subject(:instance) do
      Dea::Instance.new(bootstrap, valid_instance_attributes)
    end

    let(:droplet) do
      droplet = mock("droplet")
      droplet.stub(:droplet_exist?).and_return(true)
      droplet.stub(:droplet_dirname).and_return(File.join(tmpdir, "droplet", "some_sha1"))
      droplet.stub(:droplet_basename).and_return("droplet.tgz")
      droplet.stub(:droplet_path).and_return(File.join(droplet.droplet_dirname, droplet.droplet_basename))
      droplet
    end

    let(:runtime) do
      runtime = mock("runtime")
      runtime.stub(:dirname).and_return("/runtime_path")
      runtime
    end

    let(:warden_connection) do
      mock("warden_connection")
    end

    before do
      instance.stub(:promise_state).and_return(delivering_promise)
      instance.stub(:promise_droplet_download).and_return(delivering_promise)
      instance.stub(:promise_warden_connection).and_return(delivering_promise(warden_connection))
      instance.stub(:promise_create_container).and_return(delivering_promise)
      instance.stub(:promise_setup_network).and_return(delivering_promise)
      instance.stub(:promise_limit_disk).and_return(delivering_promise)
      instance.stub(:promise_limit_memory).and_return(delivering_promise)
      instance.stub(:promise_extract_droplet).and_return(delivering_promise)
      instance.stub(:promise_prepare_start_script).and_return(delivering_promise)
      instance.stub(:promise_start).and_return(delivering_promise)
      instance.stub(:droplet).and_return(droplet)
      instance.stub(:runtime).and_return(runtime)
      instance.stub(:start_stat_collector)
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

    describe "checking source state" do
      before do
        instance.unstub(:promise_state)
      end

      it "passes when \"born\"" do
        instance.state = Dea::Instance::State::BORN

        expect_start.to_not raise_error
      end

      it "fails when invalid" do
        instance.state = "invalid"

        expect_start.to raise_error(Dea::Instance::BaseError, /transition/)
      end
    end

    describe "downloading droplet" do
      before do
        instance.unstub(:promise_droplet_download)
      end

      describe "when it already exists" do
        before do
          droplet.stub(:droplet_exist?).and_return(true)
        end

        it "succeeds" do
          expect_start.to_not raise_error
        end
      end

      describe "when it does not yet exist" do
        before do
          droplet.stub(:droplet_exist?).and_return(false)
        end

        it "succeeds when #download succeeds" do
          droplet.stub(:download).and_yield(nil)

          expect_start.to_not raise_error
        end

        it "fails when #download fails" do
          droplet.stub(:download).and_yield(Dea::Instance::BaseError.new("download failed"))

          expect_start.to raise_error(Dea::Instance::BaseError, "download failed")
        end
      end
    end

    describe "creating warden connection" do
      before do
        instance.unstub(:promise_warden_connection)
      end

      let(:warden_socket) { File.join(tmpdir, "warden.sock") }

      before do
        bootstrap.stub(:config).and_return("warden_socket" => warden_socket)
      end

      let(:dumb_connection) do
        dumb_connection = Class.new(::EM::Connection) do
          class << self
            attr_accessor :count
          end

          def post_init
            self.class.count ||= 0
            self.class.count += 1
          end
        end
      end

      it "succeeds when connecting succeeds" do
        em do
          ::EM.start_unix_domain_server(warden_socket, dumb_connection)
          ::EM.next_tick do
            Dea::Promise.resolve(instance.promise_warden_connection(:app)) do |error, result|
              expect do
                raise error if error
              end.to_not raise_error

              # Check that the connection was made
              dumb_connection.count.should == 1

              done
            end
          end
        end
      end

      it "succeeds when cached connection can be used" do
        em do
          ::EM.start_unix_domain_server(warden_socket, dumb_connection)
          ::EM.next_tick do
            Dea::Promise.resolve(instance.promise_warden_connection(:app)) do |error, result|
              expect do
                raise error if error
              end.to_not raise_error

              # Check that the connection was made
              dumb_connection.count.should == 1

              Dea::Promise.resolve(instance.promise_warden_connection(:app)) do |error, result|
                expect do
                  raise error if error
                end.to_not raise_error

                # Check that the connection wasn't made _again_
                dumb_connection.count.should == 1

                done
              end
            end
          end
        end
      end

      it "fails when connecting fails" do
        em do
          Dea::Promise.resolve(instance.promise_warden_connection(:app)) do |error, result|
            expect do
              raise error if error
            end.to raise_error(Dea::Instance::WardenError, /cannot connect/i)

            done
          end
        end
      end
    end

    describe "creating warden container" do
      before do
        instance.unstub(:promise_create_container)
      end

      let(:response) do
        response = mock("create_response")
        response.stub(:handle).and_return("handle")
        response
      end

      it "succeeds when the call succeeds" do
        instance.stub(:promise_warden_call) do
          delivering_promise(response)
        end

        expect_start.to_not raise_error

        # Warden handle should be set
        instance.attributes["warden_handle"].should == "handle"
      end

      it "fails when the call fails" do
        instance.stub(:promise_warden_call) do
          failing_promise(RuntimeError.new("error"))
        end

        expect_start.to raise_error(RuntimeError, /error/i)

        # Warden handle should not be set
        instance.attributes["warden_handle"].should be_nil
      end
    end

    describe "setting up network" do
      before do
        instance.unstub(:promise_setup_network)
      end

      let(:response) do
        response = mock("net_in_response")
        response.stub(:host_port      => 1234)
        response.stub(:container_port => 1235)
        response
      end

      it "should make a net_in request on behalf of the container" do
        instance.attributes["warden_handle"] = "handle"

        instance.stub(:promise_warden_call) do |connection, request|
          request.should be_kind_of(::Warden::Protocol::NetInRequest)
          request.handle.should == "handle"

          delivering_promise(response)
        end

        expect_start.to_not raise_error
      end

      it "should map an instance port when the application has uris" do
        instance.attributes["application_uris"] = ["uri"]

        instance.stub(:promise_warden_call) do
          delivering_promise(response)
        end

        expect_start.to_not raise_error

        # Ports should be set
        instance.attributes["instance_host_port"].     should == 1234
        instance.attributes["instance_container_port"].should == 1235
      end

      it "should not map an instance port when the application has no uris" do
        instance.attributes["application_uris"] = []

        instance.stub(:promise_warden_call) do
          delivering_promise(response)
        end

        expect_start.to_not raise_error

        # Ports should not be set
        instance.attributes["instance_host_port"].     should be_nil
        instance.attributes["instance_container_port"].should be_nil
      end

      it "should map a debug port port if needed" do
        instance.attributes["debug"] = "debug"

        instance.stub(:promise_warden_call) do
          delivering_promise(response)
        end

        expect_start.to_not raise_error

        # Ports should be set
        instance.instance_debug_host_port.     should == 1234
        instance.instance_debug_container_port.should == 1235
      end

      it "should map a console port port if needed" do
        instance.attributes["console"] = true

        instance.stub(:promise_warden_call) do
          delivering_promise(response)
        end

        expect_start.to_not raise_error

        # Ports should be set
        instance.instance_console_host_port.     should == 1234
        instance.instance_console_container_port.should == 1235
      end

      it "can fail" do
        instance.stub(:promise_warden_call) do
          failing_promise(RuntimeError.new("error"))
        end

        expect_start.to raise_error(RuntimeError, /error/i)

        # Ports should not be set
        instance.instance_host_port.     should be_nil
        instance.instance_container_port.should be_nil
      end
    end

    describe "limiting disk" do
      before do
        instance.unstub(:promise_limit_disk)
        instance.stub(:disk_limit_in_bytes).and_return(1234)
      end

      it "should make a net_in request on behalf of the container" do
        instance.attributes["warden_handle"] = "handle"

        instance.stub(:promise_warden_call) do |connection, request|
          request.should be_kind_of(::Warden::Protocol::LimitDiskRequest)
          request.handle.should == "handle"
          request.byte.should == 1234

          delivering_promise
        end

        expect_start.to_not raise_error
      end

      it "can fail" do
        instance.stub(:promise_warden_call) do
          failing_promise(RuntimeError.new("error"))
        end

        expect_start.to raise_error(RuntimeError, /error/i)
      end
    end

    describe "limiting memory" do
      before do
        instance.unstub(:promise_limit_memory)
        instance.stub(:memory_limit_in_bytes).and_return(1234)
      end

      it "should make a net_in request on behalf of the container" do
        instance.attributes["warden_handle"] = "handle"

        instance.stub(:promise_warden_call) do |connection, request|
          request.should be_kind_of(::Warden::Protocol::LimitMemoryRequest)
          request.handle.should == "handle"
          request.limit_in_bytes.should == 1234

          delivering_promise
        end

        expect_start.to_not raise_error
      end

      it "can fail" do
        instance.stub(:promise_warden_call) do
          failing_promise(RuntimeError.new("error"))
        end

        expect_start.to raise_error(RuntimeError, /error/i)
      end
    end

    describe "running a script in a container" do
      before do
        instance.attributes["warden_handle"] = "handle"
      end

      let(:response) do
        mock("run_response")
      end

      it "should make a run request" do
        response.stub(:exit_status).and_return(0)

        instance.stub(:promise_warden_call) do |connection, request|
          request.should be_kind_of(::Warden::Protocol::RunRequest)
          request.handle.should == "handle"

          delivering_promise(response)
        end

        em do
          p = instance.promise_warden_run(warden_connection, "script")

          Dea::Promise.resolve(p) do |error, result|
            expect do
              raise error if error
            end.to_not raise_error

            done
          end
        end
      end

      it "can fail by the script failing" do
        response.stub(:exit_status).and_return(1)
        response.stub(:stdout).and_return("stdout")
        response.stub(:stderr).and_return("stderr")

        instance.stub(:promise_warden_call) do |connection, request|
          delivering_promise(response)
        end

        em do
          p = instance.promise_warden_run(warden_connection, "script")

          Dea::Promise.resolve(p) do |error, result|
            expect do
              raise error if error
            end.to raise_error(Dea::Instance::WardenError, /script exited/i)

            done
          end
        end
      end

      it "can fail by the request failing" do
        instance.stub(:promise_warden_call) do |connection, request|
          failing_promise(RuntimeError.new("error"))
        end

        em do
          p = instance.promise_warden_run(warden_connection, "script")

          Dea::Promise.resolve(p) do |error, result|
            expect do
              raise error if error
            end.to raise_error(RuntimeError, /error/i)

            done
          end
        end
      end
    end

    describe "extracting the droplet" do
      before do
        instance.unstub(:promise_extract_droplet)
      end

      it "should run tar" do
        instance.stub(:promise_warden_run) do |_, script|
          script.should =~ /tar zxf/

          delivering_promise
        end

        expect_start.to_not raise_error
      end

      it "can fail by run failing" do
        instance.stub(:promise_warden_run) do |*_|
          failing_promise(RuntimeError.new("failure"))
        end

        expect_start.to raise_error("failure")
      end
    end

    describe "preparing the start script" do
      let(:runtime) do
        runtime = mock(:runtime)
        runtime.stub(:executable).and_return("/bin/runtime")
        runtime
      end

      before do
        instance.unstub(:promise_prepare_start_script)
        instance.stub(:runtime).and_return(runtime)
      end

      it "should run sed" do
        instance.stub(:promise_warden_run) do |_, script|
          script.should =~ /^sed /

          delivering_promise
        end

        expect_start.to_not raise_error
      end

      it "can fail by run failing" do
        instance.stub(:promise_warden_run) do |*_|
          failing_promise(RuntimeError.new("failure"))
        end

        expect_start.to raise_error("failure")
      end
    end

    describe "starting the application" do
      let(:runtime) do
        runtime = mock("Dea::Runtime")
        runtime.stub(:environment).and_return({})
        runtime.stub(:debug_environment).and_return({})
        runtime
      end

      let(:response) do
        response = mock("spawn_response")
        response.stub(:job_id => 37)
        response
      end

      before do
        instance.unstub(:promise_start)
        instance.stub(:runtime).and_return(runtime)
      end

      it "executes a SpawnRequest" do
        instance.attributes["warden_handle"] = "handle"

        instance.stub(:promise_warden_call) do |connection, request|
          request.should be_kind_of(::Warden::Protocol::SpawnRequest)
          request.handle.should == "handle"
          request.script.should_not be_empty

          delivering_promise(response)
        end

        expect_start.to_not raise_error

        # Job ID should be set
        instance.attributes["warden_job_id"].should == 37
      end

      it "can fail" do
        instance.stub(:promise_warden_call) do
          failing_promise(RuntimeError.new("error"))
        end

        expect_start.to raise_error(RuntimeError, /error/i)

        # Job ID should not be set
        instance.attributes["warden_job_id"].should be_nil
      end
    end
  end

  describe "stop transition" do
    subject(:instance) do
      Dea::Instance.new(bootstrap, valid_instance_attributes)
    end

    let(:warden_connection) do
      mock("warden_connection")
    end

    before do
      instance.stub(:promise_state).and_return(delivering_promise)
      instance.stub(:promise_warden_connection).and_return(delivering_promise(warden_connection))
      instance.stub(:promise_stop).and_return(delivering_promise)
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

    describe "checking source state" do
      before do
        instance.unstub(:promise_state)
      end

      passing_states = [Dea::Instance::State::RUNNING]

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

    describe "#promise_stop" do
      before do
        instance.unstub(:promise_stop)
      end

      let(:response) do
        mock("Warden::Protocol::StopResponse")
      end

      it "executes a StopRequest" do
        instance.attributes["warden_handle"] = "handle"

        instance.stub(:promise_warden_call) do |connection, request|
          request.should be_kind_of(::Warden::Protocol::StopRequest)
          request.handle.should == "handle"

          delivering_promise(response)
        end

        expect_stop.to_not raise_error
      end

      it "can fail" do
        instance.stub(:promise_warden_call) do
          failing_promise(RuntimeError.new("error"))
        end

        expect_stop.to raise_error(RuntimeError, /error/i)
      end
    end
  end
end
