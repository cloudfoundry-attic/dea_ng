# coding: UTF-8

require "spec_helper"
require "digest/sha1"
require "dea/droplet"

describe Dea::Droplet do
  include_context "tmpdir"

  let(:payload) do
    "droplet"
  end

  let(:sha1) do
    Digest::SHA1.hexdigest(payload)
  end

  subject(:droplet) do
    Dea::Droplet.new(tmpdir, sha1)
  end

  it "should export its sha1" do
    droplet.sha1.should == sha1
  end

  it "should not exist" do
    droplet.droplet_exist?.should be_false
  end

  it "should make sure its directory exists" do
    File.directory?(droplet.droplet_dirname).should be_true
  end

  describe "destroy" do
    it "should remove the associated directory" do
      File.exist?(droplet.droplet_dirname).should be_true

      em do
        droplet.destroy { EM.stop }
        done
      end

      File.exist?(droplet.droplet_dirname).should be_false
    end
  end

  describe "download" do
    around do |example|
      em do
        example.call
      end
    end

    it "should fail when server is unreachable" do
      droplet.download("http://127.0.0.1:12346/droplet") do |err|
        err.message.should match(/status: unknown/)
        done
      end
    end

    it "should fail when response has status other than 200" do
      start_http_server(12345) do |connection, data|
        connection.send_data("HTTP/1.1 404 Not Found\r\n")
        connection.send_data("\r\n")
      end

      droplet.download("http://127.0.0.1:12345/droplet") do |err|
        err.message.should match(/status: 404/)
        done
      end
    end

    it "should fail when response payload has invalid SHA1" do
      start_http_server(12345) do |connection, data|
        connection.send_data("HTTP/1.1 200 OK\r\n")
        connection.send_data("Content-Length: 4\r\n")
        connection.send_data("\r\n")
        connection.send_data("fooz\r\n")
        connection.send_data("\r\n")
      end

      droplet.download("http://127.0.0.1:12345/droplet") do |err|
        err.message.should match(/SHA1 mismatch/)
        done
      end
    end

    describe "when successful" do
      before do
        body = payload

        start_http_server(12345) do |connection, data|
          connection.send_data("HTTP/1.1 200 OK\r\n")
          connection.send_data("Content-Length: #{body.length}\r\n")
          connection.send_data("\r\n")
          connection.send_data(body)
          connection.send_data("\r\n")

          # Taint body so subsequent requests get a different response
          body = body.succ
        end
      end

      it "should call callback without error" do
        droplet.download("http://127.0.0.1:12345/droplet") do |err|
          err.should be_nil

          # Droplet should now exist
          droplet.droplet_exist?.should be_true

          done
        end
      end

      it "should coalesce attempts at concurrent downloads" do
        in_flight = 0

        5.times do
          droplet.download("http://127.0.0.1:12345/droplet") do |err|
            err.should be_nil

            in_flight -= 1
            done if in_flight == 0
          end

          in_flight += 1
        end
      end
    end
  end
end
