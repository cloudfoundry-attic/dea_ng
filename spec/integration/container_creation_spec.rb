require "spec_helper"

require "dea/container/connection_provider"
require "dea/container/container"

describe "Creating a new container from shell command", type: :integration, requires_warden: true do
  let(:project_dir) { File.expand_path(File.join(__FILE__, "..", "..", "..")) }

  it "creates a warden container" do
    warden_container_path = "/tmp/warden/containers"

    Dir.chdir(project_dir) do
      Tempfile.open("config") do |f|
        warden_socket_path = "/tmp/warden.sock"
        configs = {
          warden_socket_path: warden_socket_path,
          bind_mounts: [
            {src_path: "/vagrant", dst_path: "/var/a", mode: "ro"}
          ]
        }
        f.write(configs.to_json)
        f.flush
        json_output = `bundle exec ./bin/create_warden_container.rb < #{f.path}`
        expect($?).to be_success
        handle = JSON.parse(json_output).fetch('handle')
        expect(Dir.entries(warden_container_path)).to include(handle)

        #EM.run do
        #  Fiber.new do
            created_container = Dea::Container.new(Dea::ConnectionProvider.new(warden_socket_path))
            created_container.handle = handle
            created_container.destroy!
            #EM.stop
          #end.resume
        #end

        expect(Dir.entries(warden_container_path)).not_to include(handle)
      end
    end
  end
end