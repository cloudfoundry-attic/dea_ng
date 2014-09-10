require "spec_helper"
require "net/http"
require "uri"
require "vcap/common"
require "securerandom"

describe "Staging an app", :type => :integration, :requires_warden => true do
  let(:unstaged_url) { "http://#{file_server_address}/unstaged/sinatra" }
  let(:staged_url) { "http://#{file_server_address}/staged/sinatra" }
  let(:buildpack_cache_download_uri) { "http://#{file_server_address}/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://#{file_server_address}/buildpack_cache" }
  let(:app_id) { "some-app-id" }
  let(:properties) { {} }
  let(:task_id) { SecureRandom.uuid }
  let(:env) { ["FOO=bar baz","BLAH=WHATEVER", "HTTP_PROXY=myproxy.com"] }
  let(:memory_limit) { 64 }
  let(:limits) do
    {
      "mem" => memory_limit,
      "disk" => 128,
      "fds" => 32
    }
  end
  let(:admin_buildpacks) { [] }

  let(:start_message) do
    {
      "index" => 1,
      "droplet" => app_id,
      "version" => "some-version",
      "name" => "some-app-name",
      "uris" => [],
      "prod" => false,
      "sha1" => nil,
      "executableUri" => nil,
      "cc_partition" => "foo",
      "limits" => limits,
      "services" => [],
      "env" => env
    }
  end

  let(:staging_message) do
    {
      "app_id" => app_id,
      "task_id" => task_id,
      "properties" => properties,
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
      "buildpack_cache_download_uri" => buildpack_cache_download_uri,
      "start_message" => start_message,
      "admin_buildpacks" => admin_buildpacks
    }
  end

  context "when admin buildpacks are specified" do
    let(:admin_buildpacks) do
      [
        {
          "url" => "http://#{file_server_address}/admin_buildpacks/admin_buildpack",
          "key" => "abcdef"
        }
      ]
    end

    it "uses admin buildpack to stage an app" do
      response, staging_log = perform_stage_request(staging_message)
      expect(staging_log).to include("-----> Some admin compilation output")
      expect(response["error"]).to be_nil
    end

    context "when having 2 admin buildpacks" do
      let(:admin_buildpacks) do
        [
          {
            "url" => "http://#{file_server_address}/admin_buildpacks/admin_buildpack",
            "key" => "abcdef"
          },
          {
            "url" => "http://#{file_server_address}/admin_buildpacks/start_command",
            "key" => "xyz"
          }
        ]
      end

      context "and a specific buildpack is requested by key" do
        let(:properties) { {"buildpack_key" => "xyz", "environment" => env, "resources" => limits} }

        it "uses the one specified in the message" do
          response, staging_log = perform_stage_request(staging_message)
          expect(staging_log).to include("-----> Start command buildpack output")
          expect(response["error"]).to be_nil
        end
      end

      context "and autodetection is requested" do
        let(:properties) { {"environment" => env, "resources" => limits} }

        context "when the buildpacks are ordered 2nd, 1st " do
          let(:admin_buildpacks) do
            [
              {
                "url" => "http://#{file_server_address}/admin_buildpacks/admin_buildpack",
                "key" => "1_sha_admin" # the number is here to ensure that we are not sorting by ls
              },
              {
                "url" => "http://#{file_server_address}/admin_buildpacks/ruby",
                "key" => "0_sha_ruby"
              }
            ]
          end

          it "uses the first matching buildpack" do
            staging_log = perform_stage_request(staging_message)[1]
            expect(staging_log).to include("-----> Some admin compilation output")
          end
        end

        context "when the buildpacks are ordered first, second" do
          let(:admin_buildpacks) do
            [
              {
                "url" => "http://#{file_server_address}/admin_buildpacks/ruby",
                "key" => "0_sha_ruby"
              },
              {
                "url" => "http://#{file_server_address}/admin_buildpacks/admin_buildpack",
                "key" => "1_sha_admin"
              }
            ]
          end

          it "uses the first matching buildpack" do
            response, staging_log = perform_stage_request(staging_message)
            expect(staging_log).to include("-----> Some compilation output")
          end
        end
      end
    end

    context "after the buildpack is deleted" do
      context "when one app has been previously deployed with the buildpack we're going to delete" do
        before do
          perform_stage_request(staging_message)
        end

        def stage_with_no_admin_buildpacks
          staging_message_with_deleted_buildpacks = staging_message.dup
          staging_message_with_deleted_buildpacks["admin_buildpacks"] = []
          perform_stage_request(staging_message_with_deleted_buildpacks)
        end

        it "no longer stages the app with the admin buildpack" do
          staging_log = stage_with_no_admin_buildpacks[1]
          expect(staging_log).to_not include("-----> Some admin compilation output")
        end

        it "deletes the buildpack from the filesystem" do
          expect {
            stage_with_no_admin_buildpacks
          }.to change{ admin_buildpack_dir_size }.by(-1)
        end
      end
    end
  end

  describe "pre-downloading admin buildpacks" do
    let(:admin_buildpacks) do
      [
        {
          "url" => "http://#{file_server_address}/admin_buildpacks/admin_buildpack",
          "key" => "predownload1"
        },
        {
          "url" => "http://#{file_server_address}/admin_buildpacks/start_command",
          "key" => "predownload2"
        }
      ]
    end

    context "after a buildpacks message has been received and processed" do
      def publish_buildpacks_announcement
        nats.publish("buildpacks", admin_buildpacks)
      end

      it "downloads buildpacks to staging workspace" do
        publish_buildpacks_announcement

        within_n_seconds(20) do
          expect(admin_buildpack_dir_size).to eq(2)
        end
      end

      def within_n_seconds(n)
        start = Time.now
        begin
          yield
          sleep 1
        rescue => e
          raise e unless (Time.now - start) < n
          retry
        end
      end
    end
  end

  def admin_buildpack_dir_size
    admin_buildpack_dir = File.join(dea_config["base_dir"], "admin_buildpacks")
    (dea_server.directory_entries(admin_buildpack_dir) - %w[. ..]).size
  end

  describe "when a buildpack url is specified" do
    before { setup_fake_buildpack("start_command") }

    shared_examples "with a valid url" do |branch|
      let(:buildpack_url) { fake_buildpack_url("start_command") + (branch ? "##{branch}" : '')}
      let(:properties) { {"buildpack" => buildpack_url, "environment" => env, "resources" => limits} }

      it "works" do
        buildpack_cache_file = File.join(FILE_SERVER_DIR, "buildpack_cache.tgz")
        FileUtils.rm_rf(buildpack_cache_file)

        response, staging_log = perform_stage_request(staging_message)

        by "downloading the buildpack and running it" do
          expect(response["error"]).to be_nil
          expect(staging_log).to include("-----> Downloaded app package")
          expect(staging_log).to include("-----> Uploading droplet")
        end

        and_by "uploading buildpack cache after staging" do
          expect(File.exist?(buildpack_cache_file)).to be_true
        end

        and_by "downloading buildpack cache before staging" do
          Dir.mktmpdir do |tmp|
            Dir.chdir(tmp) do
              `curl -s #{staged_url} | tar xfz -`
              expect(File.exist?(File.join("app", "cached_file"))).to be_true
            end
          end
        end

        and_by "cleaning the buildpack cache between staging" do
          Dir.mktmpdir do |tmp|
            Dir.chdir(tmp) do
              buildpack_cache_file = File.join(FILE_SERVER_DIR, "buildpack_cache.tgz")
              `tar -zxf #{buildpack_cache_file}`
              expect(File.exist?("new_cached_file")).to be_true
              expect(File.exist?("cached_file")).to_not be_true
            end
          end
        end

        and_by "setting the correct user environment variables" do
          expect(staging_log).to include("FOO=bar baz")
          expect(staging_log).to include("BLAH=WHATEVER")
          expect(staging_log).to include("HTTP_PROXY=myproxy.com")
        end

        and_by "setting the correct system environment variables" do
          expect(staging_log).to include("VCAP_APPLICATION=")
          expect(staging_log).to include("MEMORY_LIMIT=#{memory_limit}m")
        end
      end
    end

    context "valid git urls" do
      include_examples "with a valid url"
      include_examples "with a valid url", "a_branch"
      include_examples "with a valid url", "a_tag"
      include_examples "with a valid url", "a_lightweight_tag"
    end

    context "invalid git urls" do
      it "fails with an invalid url" do
        properties = {"buildpack" => "#{fake_buildpack_url("start_command")}1", "environment" => env, "resources" => limits}
        response, staging_log = perform_stage_request(staging_message)
        expect(response["error"]).to match /Script exited with status 1/
      end
      it "fails with an invalid branch" do
        properties = {"buildpack" => "#{fake_buildpack_url("start_command")}#badbranch", "environment" => env, "resources" => limits}
        response, staging_log = perform_stage_request(staging_message)
        expect(response["error"]).to match /Script exited with status 1/
      end
    end
  end

  context "while staging is running" do
    let(:properties) do
      setup_fake_buildpack("start_command")
      {"buildpack" => fake_buildpack_url("start_command")}
    end

    it "streams the logs back to the user" do
      _, log = perform_stage_request(staging_message)
      expect(log).to include("Downloaded app package")
    end
  end

  context "when an invalid upload URI is given" do
    let(:staged_url) { "http://localhost:45459/not_real" }

    let(:properties) do
      setup_fake_buildpack("start_command")
      {"buildpack" => fake_buildpack_url("start_command")}
    end

    before { FileUtils.rm_f(dea_server.instance_file_path) if File.exists?(dea_server.instance_file_path) }

    it "does not crash" do
      response, _ = perform_stage_request(staging_message)
      expect(response["error"]).to include("Error uploading")
      expect(dea_memory).to be > 0
    end

    it "unregisters the staging task" do
      begin
        Timeout::timeout(10) do
          perform_stage_request(staging_message)
        end
      rescue Timeout::Error
      end
      expect(instances_json["staging_tasks"]).to be_empty
    end
  end

  context "when an invalid buildpack cache upload URI" do
    let(:buildpack_cache_upload_uri) { "http://localhost:45459/not_real" }

    let(:properties) do
      setup_fake_buildpack("start_command")
      {"buildpack" => fake_buildpack_url("start_command")}
    end

    before { dea_server.remove_instance_file }

    it "does not crash" do
      response, _ = perform_stage_request(staging_message)
      expect(response["error"]).to include("Error uploading")
      expect(dea_memory).to be > 0
    end

    it "unregisters the staging task" do
      begin
        Timeout::timeout(10) do
          perform_stage_request(staging_message)
        end
      rescue Timeout::Error
      end
      expect(instances_json["staging_tasks"]).to be_empty
    end
  end

  describe "running staging tasks" do
    let(:buildpack_url) do
      setup_fake_buildpack("long_compiling_buildpack")
      fake_buildpack_url("long_compiling_buildpack")
    end

    let(:properties) { {"buildpack" => buildpack_url} }

    def available_memory_while_staging
      memory_while_staging = nil
      expected_responses = 2

      nats.make_blocking_request("staging", staging_message, expected_responses, 20) do |index, _|
        if index == 0
          NATS.publish("dea.locate", Yajl::Encoder.encode({})) do
            NATS.subscribe("dea.advertise") do |resp|
              memory_while_staging = Yajl::Parser.parse(resp)["available_memory"]

              NATS.publish("staging.stop", Yajl::Encoder.encode({"app_id" => app_id}))
            end
          end
        end
      end

      memory_while_staging
    end

    context "when the app uses less than the staging memory" do
      it "decreases the DEA's available memory by the default staging amount" do
        initial_mem = dea_memory

        expect(available_memory_while_staging).to eq(initial_mem - 1024)
        expect(dea_memory).to eq(initial_mem)
      end
    end

    context "when the app uses more than the staging memory" do
      let(:memory_limit) { 1536 }
      it "decreases the DEA's available memory by the app amount" do
        initial_mem = dea_memory

        expect(available_memory_while_staging).to eq(initial_mem - 1536)
        expect(dea_memory).to eq(initial_mem)
      end
    end

    context "when the shutdown started" do
      after { dea_start }

      context "when staging is in process" do
        it "stops staging tasks" do
          responses = nats.make_blocking_request("staging", staging_message, 2) do |response_index, _|
            dea_stop if response_index == 0
          end

          # We either get response from failed staging or stop request
          expect(responses[1]["error"]).to match /Error staging: task stopped|Script exited with status 255/
          expect(responses[1]["task_id"]).to eq(responses[0]["task_id"])
        end
      end
    end

    context "when stop request is published" do
      let(:start_message) { nil }

      it "stops staging task" do
        responses = nats.make_blocking_request("staging", staging_message, 2) do |response_index, _|
          if response_index == 0
            NATS.publish("staging.stop", Yajl::Encoder.encode("app_id" => app_id))
          end
        end

        expect(responses[1]["error"]).to eq("Error staging: task stopped")
      end
    end
  end
end
