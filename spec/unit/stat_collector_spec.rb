require "spec_helper"
require "dea/stat_collector"

describe Dea::StatCollector do
  NANOSECONDS_PER_SECOND = 1e9

  let(:container) { Container.new("some-socket") }

  let(:memory_stat_response) do
    Warden::Protocol::InfoResponse::MemoryStat.new(
      :cache => 20,
      :inactive_file => 10,
      :rss => 50,
      :total_cache => 200,
      :total_inactive_file => 100,
      :total_rss => 500
    )
  end

  let(:disk_stat_response) do
    Warden::Protocol::InfoResponse::DiskStat.new(
      :bytes_used => 42,
    )
  end

  let(:cpu_stat_response) do
    Warden::Protocol::InfoResponse::CpuStat.new(
      :usage => 5_000_000
    )
  end

  let(:info_response) do
    Warden::Protocol::InfoResponse.new(
      :state => "state",
      :memory_stat => memory_stat_response,
      :disk_stat => disk_stat_response,
      :cpu_stat => cpu_stat_response
    )
  end

  subject(:collector) do
    Dea::StatCollector.new(container)
  end

  before do
    called = false
    EM::Timer.stub(:new) do |_, &blk|
      called = true
      blk.call unless called
    end
  end

  its(:used_memory_in_bytes) { should eq 0 }
  its(:used_disk_in_bytes) { should eq 0 }
  its(:computed_pcpu) { should eq 0 }

  describe "#start" do
    before { container.stub(:info) { info_response } }

    context "first time started" do
      it "retrieves stats" do
        collector.should_receive(:retrieve_stats)
        collector.start
      end

      it "runs #retrieve_stats every X seconds" do
        collector.should_receive(:retrieve_stats).twice

        called = 0
        ::EM::Timer.stub(:new).with(Dea::StatCollector::INTERVAL) do |_, &blk|
          called += 1

          blk.call unless called == 2
        end

        collector.start

        expect(called).to eq(2)
      end
    end

    context "when already started" do
      it "return false" do
        expect(collector.start).to be_true
        expect(collector.start).to be_false
      end
    end
  end

  describe "#stop" do
    context "when already running" do
      it "stops the collector" do
        # check that calling stop stops the callback from recursing
        # by stopping it in the callback and ensuring it's not called again
        #
        # sorry
        calls = 0
        EM::Timer.stub(:new) do |_, &blk|
          calls += 1
          collector.stop if calls == 2
          blk.call unless calls == 5
        end

        collector.start

        expect(calls).to eq(2)
      end
    end

    context "when not running" do
      it "does nothing" do
        expect { collector.stop }.to_not raise_error
      end
    end
  end

  describe "#retrieve_stats" do
    context "basic usage" do
      before { container.stub(:info) { info_response } }

      before { collector.retrieve_stats(Time.now) }

      its(:used_memory_in_bytes) { should eq(600) }
      its(:used_disk_in_bytes) { should eq(42) }
      its(:computed_pcpu) { should eq(0) }
    end

    context "when retrieving info fails" do
      before { container.stub(:info) { raise "foo" } }

      it "does not propagate the error" do
        expect { collector.retrieve_stats(Time.now) }.to_not raise_error
      end

      it "keeps the same stats" do
        expect { collector.retrieve_stats(Time.now) }.to_not change {
          [ collector.used_memory_in_bytes,
            collector.used_disk_in_bytes,
            collector.computed_pcpu
          ]
        }
      end
    end

    context "and a second CPU sample comes in" do
      let(:second_info_response) do
        Warden::Protocol::InfoResponse.new(
          :state => "state",
          :memory_stat => memory_stat_response,
          :disk_stat => disk_stat_response,
          :cpu_stat => Warden::Protocol::InfoResponse::CpuStat.new(
            :usage => 100_000_000_00
          )
        )
      end

      it "uses it to compute CPU usage" do
        container.stub(:info).and_return(info_response, second_info_response)

        time = Time.now
        collector.retrieve_stats(time)
        collector.retrieve_stats(time + Dea::StatCollector::INTERVAL)

        time_between_stats = (Dea::StatCollector::INTERVAL * NANOSECONDS_PER_SECOND)
        expect(collector.computed_pcpu).to eq((10_000_000_000 - 5_000_000) / time_between_stats)
      end

      context "when disk stats are unavailable (quotas are disabled)" do
        let(:disk_stat_response) { nil }
        before { container.stub(:info) { info_response } }

        it "should report 0 bytes used" do
          collector.retrieve_stats(Time.now)
          expect(collector.used_disk_in_bytes).to eq(0)
        end

        it "should still report valid cpu statistics" do
          container.stub(:info).and_return(info_response, second_info_response)

          time = Time.now
          collector.retrieve_stats(time)
          collector.retrieve_stats(time + Dea::StatCollector::INTERVAL)

          time_between_stats = (Dea::StatCollector::INTERVAL * NANOSECONDS_PER_SECOND)
          expect(collector.computed_pcpu).to eq((10_000_000_000 - 5_000_000) / time_between_stats)
        end
      end
    end
  end
end
