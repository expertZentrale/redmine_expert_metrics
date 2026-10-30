require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# Registers itself with Redmine::Hook on definition; the hook name is unique to
# these tests, so no page ever calls it.
class ExpertMetricsPerformanceUnitHook < Redmine::Hook::Listener
  def expert_metrics_unit_test_hook(context = {})
    "seen #{context[:value]}"
  end
end

class RedmineExpertMetricsPerformanceTest < ActiveSupport::TestCase
  Performance = RedmineExpertMetrics::Performance

  def setup
    Performance::REGISTRY.reset!
    Thread.current[Performance::THREAD_KEY] = nil
  end

  def teardown
    Thread.current[Performance::THREAD_KEY] = nil
    Performance.detach!
    Setting.plugin_redmine_expert_metrics = { 'api_usage_enabled' => '0' }
  end

  # --- Registry and exposition ------------------------------------------------

  def test_histogram_renders_cumulative_buckets_sum_and_count
    registry = RedmineExpertMetrics::Registry.new
    labels = { 'controller' => 'issues', 'action' => 'show', 'format' => 'html' }.freeze
    registry.observe('redmine_http_request_duration_seconds', Performance::REQUEST_BUCKETS, labels, 0.03)
    registry.observe('redmine_http_request_duration_seconds', Performance::REQUEST_BUCKETS, labels, 0.2)
    registry.observe('redmine_http_request_duration_seconds', Performance::REQUEST_BUCKETS, labels, 45.0)

    text = RedmineExpertMetrics::Exposition.render_performance(registry.snapshot, {})
    prefix = 'redmine_http_request_duration_seconds_bucket{controller="issues",action="show",format="html",'
    assert_includes text, "# TYPE redmine_http_request_duration_seconds histogram\n"
    assert_includes text, "#{prefix}le=\"0.025\"} 0\n"
    assert_includes text, "#{prefix}le=\"0.05\"} 1\n"
    assert_includes text, "#{prefix}le=\"0.25\"} 2\n"
    assert_includes text, "#{prefix}le=\"30.0\"} 2\n"
    assert_includes text, "#{prefix}le=\"+Inf\"} 3\n"
    assert_includes text, "redmine_http_request_duration_seconds_sum{controller=\"issues\",action=\"show\",format=\"html\"} 45.23\n"
    assert_includes text, "redmine_http_request_duration_seconds_count{controller=\"issues\",action=\"show\",format=\"html\"} 3\n"
  end

  def test_counters_add_up_per_label_set
    registry = RedmineExpertMetrics::Registry.new
    labels = { 'hook' => 'view_issues_show_details_bottom', 'listener' => 'Foo::Hooks' }.freeze
    registry.increment('redmine_hook_calls_total', labels)
    registry.increment('redmine_hook_calls_total', labels.dup.freeze, 2)

    assert_equal({ labels => 3 }, registry.snapshot[:counters]['redmine_hook_calls_total'])
  end

  def test_label_sets_past_the_cap_are_booked_as_overflow
    registry = RedmineExpertMetrics::Registry.new
    (RedmineExpertMetrics::Registry::MAX_SERIES + 5).times do |i|
      registry.increment('x_total', { 'action' => "a#{i}" }.freeze)
    end

    series = registry.snapshot[:counters]['x_total']
    assert_equal RedmineExpertMetrics::Registry::MAX_SERIES + 1, series.size
    assert_equal 5, series[{ 'action' => RedmineExpertMetrics::Registry::OVERFLOW }]
  end

  def test_process_series_are_rendered
    text = RedmineExpertMetrics::Exposition.render_performance(
      Performance::REGISTRY.snapshot, Performance.process_stats
    )
    assert_includes text, '# TYPE redmine_process_start_time_seconds gauge'
    assert_match(/^redmine_ruby_threads \d+$/, text)
    if File.exist?('/proc/self/status')
      assert_match(/^redmine_process_resident_memory_bytes \d+$/, text)
    end
  end

  # --- Per-request accounting -------------------------------------------------

  def test_stats_keep_the_slowest_statements_and_count_cache_hits_apart
    stats = Performance::Stats.new
    [3.0, 9.0, 1.0, 7.0, 5.0, 8.0, 2.0].each_with_index do |ms, i|
      stats.add_sql('Issue Load', "SELECT * FROM issues WHERE id = #{i}", ms, false)
    end
    stats.add_sql('CACHE', 'SELECT 1', 0.0, true)

    assert_equal 7, stats.sql_count
    assert_equal 1, stats.sql_cached
    assert_in_delta 35.0, stats.sql_ms
    assert_equal [9.0, 8.0, 7.0, 5.0, 3.0], stats.top_sql.map { |entry| entry[:ms] }
    assert_equal 'SELECT * FROM issues WHERE id = ?', stats.top_sql.first[:sql]
  end

  def test_fingerprint_drops_literal_values
    sql = "SELECT `contacts`.* FROM `contacts` WHERE (email LIKE '%jane.doe@example.com%') " \
          "AND `contacts`.`id` IN (12, 13, 14) AND x = 'it''s' AND y = 3.5"
    fingerprint = Performance.fingerprint(sql)

    assert_not_includes fingerprint, 'jane.doe'
    assert_not_includes fingerprint, '12'
    assert_includes fingerprint, 'IN (?...)'
    assert_includes fingerprint, 'FROM `contacts`'
    assert_includes fingerprint, 'y = ?'
  end

  # MySQL/MariaDB read "..." as a string literal; PostgreSQL has dollar quoting.
  def test_fingerprint_drops_double_quoted_and_dollar_quoted_values
    skip 'double quotes are identifiers on this adapter' unless Performance.double_quoted_strings?
    fingerprint = Performance.fingerprint('SELECT * FROM users WHERE login = "jane.doe" OR mail = "a\\"b@x"')
    assert_not_includes fingerprint, 'jane.doe'
    assert_not_includes fingerprint, 'b@x'
    assert_equal 'SELECT * FROM users WHERE login = ? OR mail = ?', fingerprint
  end

  def test_fingerprint_drops_dollar_quoted_values
    fingerprint = Performance.fingerprint("SELECT $$secret one$$, $tag$secret two$tag$, $1 FROM t")
    assert_equal 'SELECT ?, ?, $? FROM t', fingerprint
  end

  def test_fingerprint_drops_scientific_and_hex_numbers
    fingerprint = Performance.fingerprint("SELECT * FROM t WHERE a = 1e10 AND b = 2.5E-3 AND c = 0xDEADBEEF AND d = X'CAFE'")
    assert_equal 'SELECT * FROM t WHERE a = ? AND b = ? AND c = ? AND d = X?', fingerprint
  end

  def test_fingerprint_is_truncated
    assert_operator Performance.fingerprint("SELECT #{'a' * 5000}").length, :<=, Performance::SQL_MAX_LENGTH + 3
  end

  def test_threshold_defaults_when_missing_or_invalid
    Setting.plugin_redmine_expert_metrics = {}
    assert_equal Performance::DEFAULT_THRESHOLD_MS, Performance.threshold_ms

    Setting.plugin_redmine_expert_metrics = { 'slow_request_threshold_ms' => 'abc' }
    assert_equal Performance::DEFAULT_THRESHOLD_MS, Performance.threshold_ms

    Setting.plugin_redmine_expert_metrics = { 'slow_request_threshold_ms' => '750' }
    assert_equal 750, Performance.threshold_ms

    Setting.plugin_redmine_expert_metrics = { 'slow_request_threshold_ms' => '0' }
    assert_equal 0, Performance.threshold_ms
  end

  def test_format_label_is_bounded
    assert_equal 'html', Performance.format_label(:html)
    assert_equal 'json', Performance.format_label('JSON')
    assert_equal 'other', Performance.format_label('*/*')
    assert_equal 'other', Performance.format_label(nil)
  end

  # --- Hooks ----------------------------------------------------------------

  def test_hook_listeners_are_timed_inside_a_request
    stats = Performance.start_request
    result = Redmine::Hook.call_hook(:expert_metrics_unit_test_hook, :value => 42)

    assert_equal ['seen 42'], result
    calls = stats.hooks[['expert_metrics_unit_test_hook', 'ExpertMetricsPerformanceUnitHook']]
    assert_not_nil calls
    assert_equal 1, calls[1]
    assert_operator stats.hooks_ms, :>=, 0.0
    assert_equal 0, stats.hook_depth
  end

  def test_hooks_outside_a_request_run_unchanged
    assert_nil Performance.current
    assert_equal ['seen 1'], Redmine::Hook.call_hook(:expert_metrics_unit_test_hook, :value => 1)
  end

  # --- Jobs -----------------------------------------------------------------

  def test_jobs_are_timed_only_while_enabled
    job = ActiveJob::Base.new
    # Attached at boot, independent of requests: job-only processes have none.
    Performance.sync_subscriptions(false)
    Setting.plugin_redmine_expert_metrics = { 'performance_metrics_enabled' => '0' }
    ActiveSupport::Notifications.instrument('perform.active_job', :job => job) {}
    assert_nil Performance::REGISTRY.snapshot[:histograms]['redmine_job_duration_seconds']

    Setting.plugin_redmine_expert_metrics = { 'performance_metrics_enabled' => '1' }
    ActiveSupport::Notifications.instrument('perform.active_job', :job => job, :exception_object => RuntimeError.new) {}
    snapshot = Performance::REGISTRY.snapshot
    labels = { 'job_class' => 'ActiveJob::Base' }
    assert_equal 1, snapshot[:histograms]['redmine_job_duration_seconds'][:series][labels][:count]
    assert_equal 1, snapshot[:counters]['redmine_job_failures_total'][labels]
  end

  # --- Subscriptions -----------------------------------------------------------

  def test_subscribers_are_attached_only_while_enabled
    Performance.sync_subscriptions(true)
    assert Performance.attached?
    Performance.sync_subscriptions(true)
    assert Performance.attached?

    Performance.sync_subscriptions(false)
    assert_not Performance.attached?
    # Detached: a statement inside an open request is not counted any more.
    stats = Performance.start_request
    ActiveRecord::Base.connection.select_value('SELECT 1')
    assert_equal 0, stats.sql_count
  end

  # --- Slow-request table -----------------------------------------------------

  def test_purge_drops_rows_past_retention
    ExpertMetricsSlowRequest.delete_all
    [ExpertMetricsSlowRequest::RETENTION_DAYS + 1, ExpertMetricsSlowRequest::RETENTION_DAYS - 1].each do |days|
      ExpertMetricsSlowRequest.create!(:created_at => Time.now - days.days, :controller_name => 'issues',
                                       :action_name => 'show', :http_method => 'GET', :request_format => 'html')
    end

    ExpertMetricsSlowRequest.purge!
    assert_equal 1, ExpertMetricsSlowRequest.count
  end

  def test_slow_writes_are_rate_limited_per_minute
    Performance.reset_slow_limit!
    allowed = Array.new(Performance::MAX_SLOW_WRITES_PER_MINUTE + 3) { Performance.slow_write_allowed? }

    assert_equal Performance::MAX_SLOW_WRITES_PER_MINUTE, allowed.count(true)
  ensure
    Performance.reset_slow_limit!
  end
end
