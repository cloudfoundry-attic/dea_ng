module Dea
  class StatCollector
    INTERVAL = 10

    attr_reader :used_memory_in_bytes
    attr_reader :used_disk_in_bytes
    attr_reader :computed_pcpu    # See `man ps`

    def initialize(container)
      @container = container
      @used_memory_in_bytes = 0
      @used_disk_in_bytes = 0
      @computed_pcpu = 0
      @cpu_samples = []
    end

    def start
      @timer ||= ::EM::Timer.new(INTERVAL) do
        retrieve_stats(Time.now)
      end
    end

    def stop
      if @timer
        @timer.cancel
        @timer = nil
      end
    end

    def retrieve_stats(now)
      info = @container.info
    rescue
      logger.error("container.info-retrieval.failed",
                  :handle => @container.handle)
    else
      @used_memory_in_bytes = info.memory_stat.rss * 1024
      @used_disk_in_bytes = info.disk_stat.bytes_used
      compute_cpu_usage(info.cpu_stat.usage, now)
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
          @computed_pcpu = used.to_f / elapsed
        end
      end
    end
  end
end