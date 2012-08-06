# coding: UTF-8

require "spec_helper"
require "dea/instance"

describe Dea::Instance do
  include_context "tmpdir"

  let(:valid_attributes) do
    {
      "instance_index"      => 37,

      "application_id"      => 37,
      "application_version" => "some_version",
      "application_name"    => "my_application",
      "application_uris"    => ["foo.com", "bar.com"],
      "application_users"   => ["john@doe.com"],

      "droplet_sha1"        => "deadbeef",
      "droplet_uri"         => "http://foo.com/file.ext",

      "runtime_name"        => "ruby19",
      "framework_name"      => "rails",

      "limits"              => { "mem" => 1, "disk" => 2, "fds" => 3 },
      "environment"         => { "FOO" => "BAR" },
      "services"            => { "name" => "redis", "type" => "redis" },
      "flapping"            => false,
    }
  end

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
          "env"      => { "FOO" => "BAR" },
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

  describe "validation" do
    before do
      bootstrap.stub(:runtimes).and_return(Hash.new { |*_| "runtime" })
    end

    it "should not raise when the attributes are valid" do
      instance = Dea::Instance.new(bootstrap, valid_attributes)

      expect do
        instance.validate
      end.to_not raise_error
    end

    it "should raise when attributes are missing" do
      attributes = valid_attributes.dup
      attributes.delete("application_id")
      instance = Dea::Instance.new(bootstrap, attributes)

      expect do
        instance.validate
      end.to raise_error
    end

    it "should raise when attributes are invalid" do
      attributes = valid_attributes.dup
      attributes["application_id"] = attributes["application_id"].to_s
      instance = Dea::Instance.new(bootstrap, attributes)

      expect do
        instance.validate
      end.to raise_error
    end

    it "should raise when the runtime is not found" do
      attributes = valid_attributes.dup
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
      instance = Dea::Instance.new(bootstrap, valid_attributes)
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

  describe "start transition" do
    subject(:instance) do
      Dea::Instance.new(bootstrap, valid_attributes)
    end

    let(:droplet) do
      droplet = mock("droplet")
      droplet.stub(:droplet_exist?).and_return(true)
      droplet.stub(:droplet_dirname).and_return(File.join(tmpdir, "droplet", "some_sha1"))
      droplet.stub(:droplet_basename).and_return("droplet.tgz")
      droplet.stub(:droplet_path).and_return(File.join(droplet.droplet_dirname, droplet.droplet_basename))
      droplet
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
      instance.stub(:promise_extract_droplet).and_return(delivering_promise)
      instance.stub(:promise_prepare_start_script).and_return(delivering_promise)
      instance.stub(:droplet).and_return(droplet)
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

      it "should map an instance port" do
        instance.stub(:promise_warden_call) do
          delivering_promise(response)
        end

        expect_start.to_not raise_error

        # Ports should be set
        instance.attributes["instance_host_port"].     should == 1234
        instance.attributes["instance_container_port"].should == 1235
      end

      it "should map a debug port port if needed" do
        instance.attributes["debug"] = "debug"

        instance.stub(:promise_warden_call) do
          delivering_promise(response)
        end

        expect_start.to_not raise_error

        # Ports should be set
        instance.attributes["instance_debug_host_port"].     should == 1234
        instance.attributes["instance_debug_container_port"].should == 1235
      end

      it "should map a console port port if needed" do
        instance.attributes["console"] = true

        instance.stub(:promise_warden_call) do
          delivering_promise(response)
        end

        expect_start.to_not raise_error

        # Ports should be set
        instance.attributes["instance_console_host_port"].     should == 1234
        instance.attributes["instance_console_container_port"].should == 1235
      end

      it "can fail" do
        instance.stub(:promise_warden_call) do
          failing_promise(RuntimeError.new("error"))
        end

        expect_start.to raise_error(RuntimeError, /error/i)

        # Ports should not be set
        instance.attributes["instance_host_port"].     should be_nil
        instance.attributes["instance_container_port"].should be_nil
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
  end
end
