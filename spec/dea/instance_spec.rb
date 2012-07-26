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
      "droplet_file"        => "file.ext",
      "droplet_uri"         => "http://foo.com/file.ext",

      "runtime_name"        => "ruby19",
      "framework_name"      => "rails",

      "limits"              => { "mem" => 1, "disk" => 2, "fds" => 3 },
      "environment"         => { "FOO" => "BAR" },
      "services"            => { "name" => "redis", "type" => "redis" },
      "flapping"            => false,
      "debug"               => "debug",
      "console"             => "console",
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
          "executableFile" => "file.ext",
          "executableUri"  => "http://foo.com/file.ext",
        }
      end

      its(:droplet_sha1) { should == "deadbeef" }
      its(:droplet_file) { should == "file.ext" }
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

  describe "start transition" do
    subject(:instance) do
      Dea::Instance.new(bootstrap, valid_attributes)
    end

    let(:droplet) do
      droplet = mock("droplet")
      droplet.stub(:droplet_exist?).and_return(true)
      droplet.stub(:droplet_directory).and_return(File.join(tmpdir, "droplet"))
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
      instance.stub(:droplet).and_return(droplet)
    end

    describe "checking source state" do
      before do
        instance.unstub(:promise_state)
      end

      it "passes when \"born\"" do
        instance.state = Dea::Instance::State::BORN

        em do
          instance.start do |error|
            error.should be_nil
            done
          end
        end
      end

      it "fails when invalid" do
        instance.state = "invalid"

        em do
          instance.start do |error|
            error.should be_kind_of(Dea::Instance::BaseError)
            error.message.should match(/transition/)
            done
          end
        end
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
          em do
            instance.start do |error|
              error.should be_nil
              done
            end
          end
        end
      end

      describe "when it does not yet exist" do
        before do
          droplet.stub(:droplet_exist?).and_return(false)
        end

        it "succeeds when #download succeeds" do
          droplet.stub(:download).and_yield(nil)

          em do
            instance.start do |error|
              error.should be_nil
              done
            end
          end
        end

        it "fails when #download fails" do
          droplet.stub(:download).and_yield(Dea::Instance::BaseError.new("download failed"))

          em do
            instance.start do |error|
              error.should be_kind_of(Dea::Instance::BaseError)
              error.message.should match(/download failed/)
              done
            end
          end
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
            instance.start do |error|
              error.should be_nil

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
            Dea::Promise.resolve(instance.promise_warden_connection(:app)) do
              # Check that the connection was made
              dumb_connection.count.should == 1

              instance.start do |error|
                error.should be_nil

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
          instance.start do |error|
            error.should be_a(Dea::Instance::WardenError)
            error.message.should match(/cannot connect/i)
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

        em do
          instance.start do |error|
            expect do
              raise error if error
            end.to_not raise_error

            # Warden handle should be set
            instance.attributes["warden_handle"].should == "handle"

            done
          end
        end
      end

      it "fails when the call fails" do
        instance.stub(:promise_warden_call) do
          failing_promise(RuntimeError.new("error"))
        end

        em do
          instance.start do |error|
            expect do
              raise error if error
            end.to raise_error(RuntimeError, /error/i)

            # Warden handle should not be set
            instance.attributes["warden_handle"].should be_nil

            done
          end
        end
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

        em do
          instance.start do |error|
            expect do
              raise error if error
            end.to_not raise_error

            done
          end
        end
      end

      it "can succeed" do
        instance.stub(:promise_warden_call) do
          delivering_promise(response)
        end

        em do
          instance.start do |error|
            expect do
              raise error if error
            end.to_not raise_error

            # Ports should be set
            instance.attributes["instance_host_port"].     should == 1234
            instance.attributes["instance_container_port"].should == 1235

            done
          end
        end
      end

      it "can fail" do
        instance.stub(:promise_warden_call) do
          failing_promise(RuntimeError.new("error"))
        end

        em do
          instance.start do |error|
            expect do
              raise error if error
            end.to raise_error(RuntimeError, /error/i)

            # Ports should not be set
            instance.attributes["instance_host_port"].     should be_nil
            instance.attributes["instance_container_port"].should be_nil

            done
          end
        end
      end
    end
  end
end
