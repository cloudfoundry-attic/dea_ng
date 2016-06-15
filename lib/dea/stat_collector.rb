require 'dea/loggregator'

module Dea
  class StatCollector
    INTERVAL = 10

    attr_reader :used_memory_in_bytes
    attr_reader :used_disk_in_bytes
    attr_reader :computed_pcpu
    attr_reader :computed_dcpu

    def initialize(container, application_id, instance_index)
     @container = container
     @application_id = application_id
     @instance_index = instance_index
     @cpu_samples = []
     @computed_pcpu = 0
     @computed_dcpu = 0
     @used_memory_in_bytes = 0
     @used_disk_in_bytes = 0
    end

    def emit_metrics(now)
      return unless @container.handle

      info = @container.info
    rescue => e
      logger.error("stat-collector.info-retrieval.failed", handle: @container.handle, error: e, backtrace: e.backtrace)
    else
      @computed_pcpu = compute_cpu_usage(info.cpu_stat.usage, now) || 0
      @used_memory_in_bytes = compute_memory_usage(info.memory_stat) || 0
      @used_disk_in_bytes = info.disk_stat ? info.disk_stat.bytes_used : 0

      Dea::Loggregator.emit_container_metric(
        @application_id, @instance_index, @computed_pcpu, @used_memory_in_bytes, @used_disk_in_bytes)
    end

    private

    def compute_cpu_usage(usage, now)
      @cpu_samples << {
        :timestamp_ns => now.to_i * 1_000_000_000 + now.nsec,
        :ns_used      => usage,
      }

      @cpu_samples.shift if @cpu_samples.size > 2

      if @cpu_samples.size == 2
        used = @cpu_samples[1][:ns_used] - @cpu_samples[0][:ns_used]
        elapsed = @cpu_samples[1][:timestamp_ns] - @cpu_samples[0][:timestamp_ns]

        if elapsed > 0
          @computed_dcpu = used.to_f / elapsed
          @computed_pcpu = (used * 100).to_f / elapsed
        end
      end
    end

    def compute_memory_usage(memory_stat)
      return memory_stat.total_rss + memory_stat.total_cache - memory_stat.total_inactive_file
    end
  end
end
