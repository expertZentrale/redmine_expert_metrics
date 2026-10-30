require 'monitor'

# In-process counters and histograms for the performance metrics. Unlike the
# Collector snapshot, which comes from the database and is the same on every
# pod, these live in the memory of one Redmine process: every pod reports its
# own, Prometheus scrapes each pod, and dashboards aggregate them with `sum`.
# A restart starts at zero, which Prometheus' rate() treats as a counter reset.
#
# Thread-safe: Puma serves requests on several threads per process. Monitor
# rather than Mutex because #update holds the lock while calling the
# (locking) writers.
module RedmineExpertMetrics
  class Registry
    # Upper bound of label sets per metric. Labels come from routes, hooks and
    # job classes, so the real number is a few hundred at most; the cap only
    # guards memory against something unexpected. Label sets past it are booked
    # under OVERFLOW instead of being dropped, so totals stay right.
    MAX_SERIES = 2000
    OVERFLOW = '_overflow'.freeze

    def initialize
      @lock = Monitor.new
      @counters = {}
      @histograms = {}
    end

    # Several writes under one lock, as one consistent step for a scrape.
    def update
      @lock.synchronize { yield self }
    end

    def increment(name, labels, by = 1)
      @lock.synchronize do
        series = (@counters[name] ||= {})
        key = series_key(series, labels)
        series[key] = series.fetch(key, 0) + by
      end
    end

    # +bounds+: ascending upper bounds without +Inf. Buckets are stored
    # non-cumulative and summed up when rendering.
    def observe(name, bounds, labels, value)
      @lock.synchronize do
        metric = (@histograms[name] ||= { :bounds => bounds, :series => {} })
        key = series_key(metric[:series], labels)
        data = (metric[:series][key] ||= { :buckets => Array.new(metric[:bounds].size + 1, 0), :sum => 0.0, :count => 0 })
        index = metric[:bounds].index { |bound| value <= bound } || metric[:bounds].size
        data[:buckets][index] += 1
        data[:sum] += value
        data[:count] += 1
      end
    end

    # Deep copy, so rendering runs without the lock:
    #   { :counters => { name => { labels => value } },
    #     :histograms => { name => { :bounds => [...], :series => { labels => { :buckets, :sum, :count } } } } }
    def snapshot
      @lock.synchronize do
        {
          :counters => @counters.each_with_object({}) { |(name, series), out| out[name] = series.dup },
          :histograms => @histograms.each_with_object({}) do |(name, metric), out|
            out[name] = {
              :bounds => metric[:bounds],
              :series => metric[:series].each_with_object({}) do |(labels, data), copy|
                copy[labels] = { :buckets => data[:buckets].dup, :sum => data[:sum], :count => data[:count] }
              end
            }
          end
        }
      end
    end

    def reset!
      @lock.synchronize do
        @counters.clear
        @histograms.clear
      end
    end

    private

    def series_key(series, labels)
      return labels if series.key?(labels) || series.size < MAX_SERIES
      labels.each_with_object({}) { |(key, _), out| out[key] = OVERFLOW }.freeze
    end
  end
end
