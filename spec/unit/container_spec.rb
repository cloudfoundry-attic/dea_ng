require "spec_helper"
require "dea/container"

describe Dea::Container do
  let(:handle) { "17deadbeef" }
  let(:socket_path) { "/tmp/warden.sock.notreally" }

  subject(:container) { described_class.new(handle, socket_path) }

  describe "#handle" do
    it "returns the handle of the container" do
      expect(container.handle).to eq("17deadbeef")
    end
  end

  describe "#socket_path" do
    it "returns the socket of the container" do
      expect(container.socket_path).to eq("/tmp/warden.sock.notreally")
    end
  end

  describe "interacting with the container" do
    let(:client) { double("client") }

    # can't yield from root fiber, and this object is
    # assumed to be run from another fiber anyway
    around { |example| Fiber.new(&example).resume }

    before { container.stub(:client => client) }

    describe "#info" do
      let(:result) { double("result") }

      it "sends an info request to the container" do
        called = false
        client.should_receive(:call) do |request|
          called = true
          expect(request).to be_a(::Warden::Protocol::InfoRequest)
          expect(request.handle).to eq("17deadbeef")
        end

        container.info

        expect(called).to be_true
      end

      context "when the request fails" do
        it "raises an exception" do
          client.should_receive(:call).and_raise("foo")

          expect { container.info }.to raise_error("foo")
        end
      end
    end
  end
end