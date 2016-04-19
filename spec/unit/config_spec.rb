require "spec_helper"
require "dea/config"

module Dea
  describe Config do

    subject(:config) { described_class.new(config_hash) }
    let(:config_hash) do
      {
        "base_dir" => "dir",
        "logging" => {
          "level" => "level"
        },
        "nats_servers" => ["nats_server1"],
        "pid_filename" => "pid_filename",
        "warden_socket" => "socket",
        "index" => 0,
        "directory_server" => {
          "protocol" => "protocol",
          "v2_port" => 7,
          "file_api_port" => 8
        },
        "cc_url" => "cc.example.com",
        "hm9000" => {
          "listener_uri" => "https://a.b.c.d:1234",
          "key_file" => fixture("/certs/hm9000_client.key"),
          "cert_file" => fixture("/certs/hm9000_client.crt"),
          "ca_file" => fixture("/certs/hm9000_ca.crt")
        }
      }
    end
    let(:disk_inode_limit) { 123456 }

    describe ".from_file" do
      let(:file_path) { File.expand_path("../../../config/dea.yml", __FILE__) }
      subject { Dea::Config.from_file(file_path) }

      it "can load" do
        expect(subject).to be_a(Dea::Config)
      end
    end

    describe '#validate' do
      before do
        allow(subject).to receive(:verify_hm9000_certs)
      end

      it 'calls the correct validation methods' do
        expect(subject).to receive(:verify_hm9000_certs)
        expect(subject).to receive(:verify_ssl_certs)
        expect(subject).to receive(:validate_router_register_interval!)
        expect { subject.validate }.to_not raise_error
      end
    end

    describe "#initialize" do
      let(:config_hash) { { } }

      it "can load" do
        allow(File).to receive(:exists?).with('spec/fixtures/spec/hm9000_client.crt').and_return(true)
        allow(File).to receive(:exists?).with('spec/fixtures/spec/hm9000_client.key').and_return(true)
        expect(subject).to be_a(Dea::Config)
      end

      describe "the available keys and values" do
        let(:config_as_hash) do
          config.inject({}) do |hash, kv|
            hash[kv[0]] = kv[1]
            hash
          end
        end

        it "has the expected default keys" do
          expect(config_as_hash.keys).to eq(Config::EMPTY_CONFIG.keys)
        end

        it "has the expected default values" do
          expect(config_as_hash.values).to eq(Config::EMPTY_CONFIG.values)
        end
      end
    end

    describe "#placement_properties" do
      context "when the config hash has no key for placement_properties:" do
        let(:config_hash) { { } }

        it "has a sane default" do
          expect(config["placement_properties"]).to eq({ "zone" => "default" })
        end
      end

      context "when the config hash has a key for placement_properties:" do
        let(:config_hash) { { "placement_properties" => { "zone" => "CRAZY_TOWN" } } }

        it "uses the zone provided by the hash" do
          expect(config["placement_properties"]).to eq({ "zone" => "CRAZY_TOWN" })
        end
      end
    end

    describe '#rootfs_path' do
      let(:stacks) { [{ 'name' => 'my-stack', 'package_path' => '/path/to/rootfs' }] }
      let(:config_hash) { { 'stacks' => stacks } }

      context 'when the stack name exists in the config' do
        let(:stack_name) { 'my-stack' }

        it 'returns the associated rootfs path' do
          expect(config.rootfs_path(stack_name)).to eq('/path/to/rootfs')
        end
      end

      context 'when the stack name does not exist in the config' do
        it 'returns nil' do
          expect(config.rootfs_path('not-exist')).to be_nil
        end
      end
    end

    describe "#staging_disk_inode_limit" do
      context "when the config hash has no key for staging disk inode limit" do
        let(:config_hash) { { "staging" => { } } }

        it "is 200_000 or larger" do
          expect(described_class::DEFAULT_STAGING_DISK_INODE_LIMIT).to be >= 200_000
        end

        it "provides a reasonable default" do
          expect(config.staging_disk_inode_limit).to eq(described_class::DEFAULT_STAGING_DISK_INODE_LIMIT)
        end
      end

      context "when the config hash has a key for staging disk inode limit" do
        let(:config_hash) { { "staging" => { "disk_inode_limit" => disk_inode_limit } } }

        it "provides a reasonable default" do
          expect(config.staging_disk_inode_limit).to eq(disk_inode_limit)
        end
      end
    end

    describe "#instance_disk_inode_limit" do
      context "when the config hash has no key for instance disk inode limit" do
        let(:config_hash) { { "instance" => { } } }

        it "is 200_000 or larger" do
          expect(described_class::DEFAULT_INSTANCE_DISK_INODE_LIMIT).to be >= 200_000
        end

        it "provides a reasonable default" do
          expect(config.instance_disk_inode_limit).to eq(described_class::DEFAULT_INSTANCE_DISK_INODE_LIMIT)
        end
      end

      context "when the config hash has a key for instance disk inode limit" do
        let(:config_hash) { { "instance" => { "disk_inode_limit" => disk_inode_limit } } }

        it "provides a reasonable default" do
          expect(config.instance_disk_inode_limit).to eq(disk_inode_limit)
        end
      end
    end

    describe "#instance_nproc_limit" do
      context "when the config hash has no key for nproc limit" do
        let(:config_hash) { { "instance" => { } } }

        it "is set to the default" do
          expect(config.instance_nproc_limit).to eq(described_class::DEFAULT_INSTANCE_NPROC_LIMIT)
        end
      end

      context "when the config hash has nproc_limit defined" do
        let(:nproc_limit) { 1024 }
        let(:config_hash) { { "instance" => { "nproc_limit" => nproc_limit } } }

        it "returns the nproc limit" do
          expect(config.instance_nproc_limit).to eq(nproc_limit)
        end
      end
    end

    describe "#staging_bandwidth_limit" do
      context "when the config hash does not have a staging bandwidth limit" do
        let(:config_hash) { { "staging" => {} } }

        it "returns nil" do
          expect(config.staging_bandwidth_limit).to be_nil
        end
      end

      context "when the config hash has a staging_bandwidth_limit defined" do
        let(:bandwidth) { { "rate" => 1000000, "burst" => 2000000 } }
        let(:config_hash) { { "staging" => { "bandwidth_limit" => bandwidth } } }

        it "returns the staging bandwidth limit" do
          expect(config.staging_bandwidth_limit).to eq(bandwidth)
        end
      end
    end

    describe "#instance_bandwidth_limit" do
      context "when the config hash does not have an instance bandwidth limit" do
        let(:config_hash) { { "instance" => {} } }

        it "returns nil" do
          expect(config.instance_bandwidth_limit).to be_nil
        end
      end

      context "when the config hash has an instance_bandwidth_limit defined" do
        let(:bandwidth) { { "rate" => 1000000, "burst" => 2000000 } }
        let(:config_hash) { { "instance" => { "bandwidth_limit" => bandwidth } } }

        it "returns the instance bandwidth limit" do
          expect(config.instance_bandwidth_limit).to eq(bandwidth)
        end
      end
    end

    describe "registration interval validation" do
      context "when the interval is greater than zero" do
        let(:config_hash) { { "intervals" => { "router_register_in_seconds" => 10 } } }

        it "is valid" do
          expect { config.validate_router_register_interval! }.to_not raise_error
        end
      end

      context "when the interval is invalid" do
        context "when the interval is zero" do
          let(:config_hash) { { "intervals" => { "router_register_in_seconds" => 0 } } }

          it "is not valid" do
            expect { config.validate_router_register_interval! }.to raise_error 'Invalid router register interval'
          end
        end

        context "when the interval is negative" do
          let(:config_hash) { { "intervals" => { "router_register_in_seconds" => -5 } } }

          it "is not valid" do
            expect { config.validate_router_register_interval! }.to raise_error 'Invalid router register interval'
          end
        end
      end

      context "when the interval not specified" do
        let (:config_hash) { { "intervals" => { } } }

        it "is sets it to the default value" do
          expect { config.validate_router_register_interval! }.to_not raise_error
          expect(config["intervals"]["router_register_in_seconds"]).to eq(20)
        end
      end
    end

    describe '#verify_hm9000_certs' do
      context 'when all certs specified exist' do
        before do
          config_hash['hm9000'] = {
            "key_file" => fixture("/certs/hm9000_client.key"),
            "cert_file" => fixture("/certs/hm9000_client.crt"),
            "ca_file" => fixture("/certs/hm9000_ca.crt")
          }
        end

        it 'verifies their existence' do
          expect{ config.verify_hm9000_certs }.to_not raise_error
        end
      end

      context 'when none of the hm9000 certs exist' do
        let(:missing_files) { [ 'fake-client-key', 'fake-cert-file', 'fake-ca-file' ] }
        let(:missing_file_list) { missing_files.join(', ')}

        before do
          config_hash['hm9000'] = {
            "key_file" => missing_files[0],
            "cert_file" => missing_files[1],
            "ca_file" => missing_files[2]
          }
        end

        it 'raises an error' do
          expect{ config.verify_hm9000_certs }.to raise_error "Invalid HM9000 Certs: One or more files not found: #{missing_file_list}"
        end
      end

      context 'when at least one  of the hm9000 certs does not exist' do
        let(:missing_file) { 'fake-ca-file' }
        before do
          config_hash['hm9000'] = {
            "key_file" => fixture("/certs/hm9000_client.key"),
            "cert_file" => fixture("/certs/hm9000_client.crt"),
            "ca_file" => missing_file
          }
        end

        it 'raises an error' do
          expect{ config.verify_hm9000_certs }.to raise_error "Invalid HM9000 Certs: One or more files not found: #{missing_file}"
        end
      end
    end

    describe '#verify_ssl_certs' do
      context 'when ssl is not enabled' do
        before do
          config_hash.delete('ssl')
        end

        it 'passes validation' do
          expect{ config.verify_ssl_certs }.to_not raise_error
        end
      end

      context 'when all certs specified exist' do
        before do
          config_hash['ssl'] = {
            "port" => 666,
            "key_file" => fixture("/certs/hm9000_client.key"),
            "cert_file" => fixture("/certs/hm9000_client.crt")
          }
        end

        it 'verifies their existence' do
          expect{ config.verify_ssl_certs }.to_not raise_error
        end
      end

      context 'when none of the ssl certs exist' do
        let(:missing_files) { [ 'fake-client-key', 'fake-cert-file'] }
        let(:missing_file_list) { missing_files.join(', ')}

        before do
          config_hash['ssl'] = {
            "port" => 5050,
            "key_file" => missing_files[0],
            "cert_file" => missing_files[1]
          }
        end

        it 'raises an error' do
          expect{ config.verify_ssl_certs }.to raise_error "Invalid SSL Certs: One or more files not found: #{missing_file_list}"
        end
      end

      context 'when at least one  of the ssl certs does not exist' do
        let(:missing_file) { 'fake-ca-file' }
        before do
          config_hash['ssl'] = {
            "port" => 5280,
            "key_file" => fixture("/certs/hm9000_client.key"),
            "cert_file" => missing_file
          }
        end

        it 'raises an error' do
          expect{ config.verify_ssl_certs }.to raise_error "Invalid SSL Certs: One or more files not found: #{missing_file}"
        end
      end
    end

    describe "post_setup_hook" do
      it 'returns nil when not set' do
        expect(config.post_setup_hook).to be_nil
      end

      it 'returns the value when set' do
        config_hash["post_setup_hook"] = 'the-value'
        expect(config.post_setup_hook).to eq('the-value')
      end

      context "when it is not a string" do
        before do
          config_hash["post_setup_hook"] = 7
        end

        it "is not valid" do
          expect { config.validate }.to raise_error Membrane::SchemaValidationError
        end
      end
    end
  end
end
