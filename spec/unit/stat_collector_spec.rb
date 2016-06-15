require "spec_helper"
require "dea/stat_collector"
require "container/container"

describe Dea::StatCollector do
  NANOSECONDS_PER_SECOND = 1e9

  let(:container) do
    c = Container.new("some-socket")
    c.handle = 'handle'
    c
  end

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
    Dea::StatCollector.new(container, "application-id", 32)
  end

  it 'initializes the statistic variables to 0' do
    expect(collector.computed_pcpu).to eq(0)
    expect(collector.computed_dcpu).to eq(0)
    expect(collector.used_memory_in_bytes).to eq(0)
    expect(collector.used_disk_in_bytes).to eq(0)
  end

  before do
    called = false
    allow(EM::Timer).to receive(:new) do |_, &blk|
      called = true
      blk.call unless called
    end

    @emitter = FakeEmitter.new
    @staging_emitter = FakeEmitter.new
    Dea::Loggregator.emitter = @emitter
    Dea::Loggregator.staging_emitter = @staging_emitter
  end

  describe "#emit_metrics" do
    let(:expected_memory_usage) { 600 }
    let(:expected_disk_usage) { 42 }
    before do
      @emitter = FakeEmitter.new
      @staging_emitter = FakeEmitter.new
      Dea::Loggregator.emitter = @emitter
      Dea::Loggregator.staging_emitter = @staging_emitter

      allow(container).to receive(:info).and_return(info_response)
    end

    it "emits metrics to loggregator" do
      collector.emit_metrics(Time.now())

      expect(@emitter.messages["application-id"].length).to eq(1)
      expect(@emitter.messages["application-id"][0][:instanceIndex]).to eq(32)
      expect(@emitter.messages["application-id"][0][:memoryBytes]).to eq(expected_memory_usage)
      expect(@emitter.messages["application-id"][0][:diskBytes]).to eq(expected_disk_usage)
      expect(@emitter.messages["application-id"][0][:cpuPercentage]).to eq(0)
    end

    it 'sets the statistics variables' do
      collector.emit_metrics(Time.now())

      expect(collector.computed_pcpu).to eq(0)
      expect(collector.computed_dcpu).to eq(0)
      expect(collector.used_memory_in_bytes).to eq(expected_memory_usage)
      expect(collector.used_disk_in_bytes).to eq(expected_disk_usage)
    end

    context 'when the handle is nil' do
      before do
        container.handle = nil
      end

      it 'does not retrieve container info' do
        expect(container).not_to receive(:info)
        collector.emit_metrics(Time.now())
      end
    end

    context "when retrieving info fails" do
      before { allow(container).to receive(:info) { raise "foo" } }

      it "does not propagate the error and logs it" do
        expect_any_instance_of(Steno::Logger).to receive(:error)
        expect { collector.emit_metrics(Time.now) }.to_not raise_error
      end

      it "emits no new stats" do
        expect(@emitter.messages['application-id']).to be_nil
      end
    end

    context "and a second CPU sample comes in" do
      let(:second_info_response) do
        Warden::Protocol::InfoResponse.new(
          :state => "state",
          :memory_stat => Warden::Protocol::InfoResponse::MemoryStat.new(
            :cache => 20,
            :inactive_file => 10,
            :rss => 50,
            :total_cache => 300,
            :total_inactive_file => 100,
            :total_rss => 800
          ),
          :disk_stat => Warden::Protocol::InfoResponse::DiskStat.new(
            :bytes_used => 78,
          ),
          :cpu_stat => Warden::Protocol::InfoResponse::CpuStat.new(
            :usage => 100_000_000_00
          )
        )
      end

      it "uses it to compute CPU usage" do
        allow(container).to receive(:info).and_return(info_response, second_info_response)

        time = Time.now

        collector.emit_metrics(time)
        collector.emit_metrics(time + Dea::StatCollector::INTERVAL)

        time_between_stats = (Dea::StatCollector::INTERVAL * NANOSECONDS_PER_SECOND)

        expect(@emitter.messages['application-id'].length).to eq(2)
        expect(@emitter.messages['application-id'][1][:cpuPercentage]).to eq((10_000_000_000 - 5_000_000) * 100 / time_between_stats)
      end

      it 'updates the statistic variables' do
        expect(container).to receive(:info).and_return(info_response, second_info_response)

        time = Time.now
        collector.emit_metrics(time)
        collector.emit_metrics(time + Dea::StatCollector::INTERVAL)

        time_between_stats = (Dea::StatCollector::INTERVAL * NANOSECONDS_PER_SECOND)
        expected_pcpu = (10_000_000_000 - 5_000_000) * 100 / time_between_stats
        expected_dcpu = expected_pcpu / 100.0

        expect(collector.computed_pcpu).to eq(expected_pcpu)
        expect(collector.computed_dcpu).to eq(expected_dcpu)
        expect(collector.used_memory_in_bytes).to eq(1000)
        expect(collector.used_disk_in_bytes).to eq(78)
      end

      context "when disk stats are unavailable (quotas are disabled)" do
        let(:disk_stat_response) { nil }
        before { allow(container).to receive(:info) { info_response } }

        it "should report 0 bytes used" do
          collector.emit_metrics(Time.now)

          expect(@emitter.messages['application-id'].length).to eq(1)
          expect(@emitter.messages['application-id'][0][:diskBytes]).to eq(0)

        end

        it "should still report valid cpu statistics" do
          expect(container).to receive(:info).and_return(info_response, second_info_response)

          time = Time.now
          collector.emit_metrics(time)
          collector.emit_metrics(time + Dea::StatCollector::INTERVAL)

          time_between_stats = (Dea::StatCollector::INTERVAL * NANOSECONDS_PER_SECOND)
          expected_pcpu = (10_000_000_000 - 5_000_000) * 100 / time_between_stats

          expect(@emitter.messages['application-id'].length).to eq(2)
          expect(@emitter.messages['application-id'][1][:cpuPercentage]).to eq(expected_pcpu)
        end
      end
    end
  end
end
